"""
    AbstractExecutorGroup
Executor group is a convenient tool for managing a group of executors.
"""
abstract AbstractExecutorGroup

function forward(self::AbstractExecutorGroup, data_provider :: AbstractDataProvider,
                 data_batch :: AbstractDataBatch, is_train)
  throw(MethodError(forward, (self, )))
end

"""
    DataParallelExecutorGroup

Supports:
  - Fixed parameters (freezing)
  - Shape inference
  - Type inference
"""
type DataParallelExecutorGroup <: AbstractExecutorGroup
  symbol :: SymbolicNode
  context :: Vector{Context}
  execs :: Vector{Executor}

  data_shapes :: Dict{Symbol, Tuple{Vararg{Int}}}
  label_shapes :: Dict{Symbol, Tuple{Vararg{Int}}}

  for_training :: Bool
  slices :: Vector{UnitRange{Int}}
  batch_size :: Int

  shared_group :: Nullable{DataParallelExecutorGroup}
  inputs_need_grad :: Bool
  fixed_param_names :: Nullable{Vector{Symbol}}
  grad_req :: Dict{Symbol, GRAD_REQ}
  freeze_idx

  data_arrays :: Vector{Vector{SlicedNDArray}}
  label_arrays :: Vector{Vector{SlicedNDArray}}
  param_arrays :: Vector{Vector{NDArray}}
  grad_arrays :: Vector{Vector{NDArray}}
  aux_arrays :: Vector{Vector{NDArray}}
  input_grad_arrays :: Vector{Vector{NDArray}}

  arg_params :: Dict{Symbol, NDArray}
  aux_params :: Dict{Symbol, NDArray}
  param_names :: Vector{Symbol}
  aux_names :: Vector{Symbol}
end

function DataParallelExecutorGroup(symbol::SymbolicNode, context::Vector{Context},
           data_shapes, data_names, data_types, label_shapes, label_names, label_types,
           for_training, inputs_need_grad, shared_group, fixed_param_names, grad_req)

  num_dev = length(context)
  arg_names  = list_arguments(symbol)
  input_names = [data_names; label_names]
  param_names  = setdiff(arg_names, input_names)
  aux_names = list_auxiliary_states(symbol)

  batch_size = data_shapes[1][end]
  for shape in data_shapes
    @assert batch_size == shape[end]
  end
  if !isempty(label_shapes)
    for shape in label_shapes
      @assert batch_size == shape[end]
    end
  end

  # TODO implement workload
  slices = _split_inputs(batch_size, num_dev)

  execs = Vector{Executor}(num_dev)

  # Shape inference based on data_shapes and label_shapes
  provided_shapes = merge(
      Dict(name => shape for (name, shape) in zip(data_names, data_shapes)),
      Dict(name => shape for (name, shape) in zip(label_names, label_shapes))
  )

  # Run shape inference globally
  arg_shapes, out_shapes, aux_shapes = infer_shape(symbol, provided_shapes)
  @assert(!isa(arg_shapes, Void), "Information not enough to perform complete shape inference")

  # Type inference based on data_types and lable_types
  provided_types = merge(
      Dict(name => T for (name, T) in zip(data_names, data_types)),
      Dict(name => T for (name, T) in zip(label_names, label_types))
  )

  arg_types, out_types, aux_types = infer_type(symbol, provided_types)

  # Check for what arg we needs gradients and which are frozen
  grad_req, freeze_idx = get_grads(symbol, param_names, arg_names, data_names, inputs_need_grad, fixed_param_names, grad_req)

  arg_params = Dict{Symbol, NDArray}()
  aux_params = Dict{Symbol, NDArray}()

  for (name, shape, T) in filter(x -> in(x[1], param_names), zip(arg_names, arg_shapes, arg_types))
    arg_params[name] = empty(T, shape)
  end

  for (name, shape, T) in zip(aux_names, aux_shapes, aux_types)
    aux_params[name] = empty(T, shape)
  end

  dev_shapes(shapes, slice) = (tuple(shape[1:end-1]..., slice) for shape in shapes)

  for i = 1:num_dev
    slice = length(slices[i])
    # Shape inference based on data_shapes and label_shapes per device
    provided_shapes_dev = merge(
        Dict(name => shape for (name, shape) in zip(data_names,  dev_shapes(data_shapes,  slice))),
        Dict(name => shape for (name, shape) in zip(label_names, dev_shapes(label_shapes, slice)))
    )

    # Run shape inference locally (per-device)
    arg_shapes_dev, out_shapes_dev, aux_shapes_dev = infer_shape(symbol, provided_shapes_dev)
    @assert(!isa(arg_shapes_dev, Void), "Information not enough to perform complete shape inference")

    arg_arrays = NDArray[zeros(T, shape, context[i]) for (shape, T) in zip(arg_shapes_dev, arg_types)]
    aux_arrays = NDArray[zeros(T, shape, context[i]) for (shape, T) in zip(aux_shapes_dev, aux_types)]

    # Process arguments to create gradient arrays
    grad_arrays = Dict{Symbol,NDArray}()
    arg_info = zip(arg_names, arg_shapes_dev, arg_types)

    # if not in provided data, should be parameters
    if inputs_need_grad
      provided_data_names = label_names
    else
      provided_data_names = [data_names; label_names]
    end
    arg_info = filter(x -> !in(x[1], provided_data_names), arg_info)

    # Remove all gradients for nop params
    arg_info = filter(x -> grad_req[x[1]] != GRAD_NOP, arg_info)

    for (name, shape, T) in arg_info
      grad_arrays[name] = zeros(T, shape, context[i])
    end

    execs[i] = bind(symbol, context[i], arg_arrays, args_grad=grad_arrays, grad_req=grad_req, aux_states=aux_arrays)
  end

  # set up input data structures
  data_arrays  = [SlicedNDArray[(slices[i], exec.arg_dict[name]) for (i,exec) in enumerate(execs)] for name in data_names]
  label_arrays = [SlicedNDArray[(slices[i], exec.arg_dict[name]) for (i,exec) in enumerate(execs)] for name in label_names]

  param_idx    = filter(i -> in(arg_names[i], param_names), 1:length(arg_names))
  name_idx     = filter(i -> in(arg_names[i], data_names), 1:length(arg_names))

  param_arrays = [NDArray[exec.arg_arrays[i] for exec in execs] for i in param_idx]
  grad_arrays  = [NDArray[exec.grad_arrays[i] for exec in execs] for i in param_idx]
  aux_arrays   = [NDArray[exec.aux_arrays[i] for exec in execs] for i = 1:length(aux_names)]

  if inputs_need_grad
    input_grad_arrays = [NDArray[exec.grad_arrays[i] for exec in execs] for i in name_idx]
  else
    input_grad_arrays = []
  end

  data_shapes = Dict(name => shape for (name, shape) in zip(data_names, data_shapes))
  label_shapes = Dict(name => shape for (name, shape) in zip(label_names, label_shapes))

  return DataParallelExecutorGroup(
    symbol, context, execs,
    data_shapes, label_shapes, for_training, slices, batch_size,
    shared_group, inputs_need_grad, fixed_param_names, grad_req, freeze_idx,
    data_arrays, label_arrays, param_arrays, grad_arrays, aux_arrays,
    input_grad_arrays, arg_params, aux_params, param_names, aux_names)
end

"""
    forward(exec_group, data_batch, is_train)
Split `data_batch` according to workload and run forward on each devices.
# Arguments
* `data_batch` : AbstractDataBatch
* `is_train` : `Bool`
  The hint for the backend, indicating whether we are during training phase.
  Default is `nothing`, then the value `self.for_training` will be used.
"""
function forward(self:: DataParallelExecutorGroup, data_provider :: AbstractDataProvider, data_batch :: AbstractDataBatch, is_train::Bool = self.for_training)

  load_data!(data_provider, data_batch, self.data_arrays)

  if is_train && !isempty(get_label(data_provider, data_batch))
    load_label!(data_provider, data_batch, self.label_arrays)
  end

  for exec in self.execs
    forward(exec, is_train=is_train)
  end
   # TODO add callbacks here
end

# TODO Add description
backward(self::DataParallelExecutorGroup, out_grads::Void) = backward(self, NDArray[])
backward(self::DataParallelExecutorGroup, out_grads::NDArray) = backward(self, [out_grads])
function backward(self::DataParallelExecutorGroup, out_grads::Vector{NDArray})
  @assert(self.for_training, "re-bind with for_training=true to run backward")

  for (i, exec) in enumerate(self.execs)
    out_grad_slices = NDArray[]
    for grad in out_grads
      push!(out_grad_slices, copy(grad, self.context[i]))
    end
    backward(exec, out_grad_slices)
  end
end

"""
    set_params!(self::DataParallelExecutorGroup, arg_params, aux_params; allow_extra_params)

Assign, i.e. copy parameters to all the executors.
# Arguments
* `arg_params` : `Dict{Symbol, NDArray}`
  A dictionary of name to `NDArray` parameter mapping.
* `aux_params` : `Dict{Symbol, NDArray}`
  A dictionary of name to `NDArray` auxiliary variable mapping.
* `allow_extra_params`: `Bool`, default `false`, allow parameters in `arg_params` or `aux_params` that not exists in `self`.
"""
function set_params!(self::DataParallelExecutorGroup,
                    arg_params, aux_params; allow_extra_params::Bool = false)
  for exec in self.execs
    copy_params_from(exec, arg_params, aux_params, allow_extra_params=allow_extra_params)
  end
end

##
# Utility
##

update_params(self::DataParallelExecutorGroup, updater, update_on_kvstore, kvstore::Void = nothing) = update_params(self, updater, update_on_kvstore, Nullable{KVStore}())
update_params(self::DataParallelExecutorGroup, updater, update_on_kvstore, kvstore::KVStore) = update_params(self, updater, update_on_kvstore, Nullable(kvstore))
function update_params(self::DataParallelExecutorGroup, updater, update_on_kvstore, kvstore::Nullable{KVStore})
  num_dev = length(self.context)
  for idx = 1:length(self.param_names)
    #= if isa(self.grad_arrays[i][1], Void) =#
    #=   continue =#
    #= end =#
    if in(idx, self.freeze_idx)
      continue # Skip parameter update entirely
    end
    if !isnull(kvstore)
      kvstore = get(kvstore)
      # push gradient, priority is negative index
      push!(kvstore, idx, self.param_arrays[idx], priority=-idx)
      if update_on_kvstore
        # pull back the weights
        pull!(kvstore, idx, self.param_arrays[idx], priority=-idx)
      else
        # pull back the sum-ed gradients, to the same locations
        pull!(kvstore, idx, self.grad_arrays[idx], priority=-idx)
      end
    end

    if !update_on_kvstore
      # manual updating
      for i_dev = 1:num_dev
        # create a fake index, so that the updater create states
        # for different param AND different devices, TODO(mli)
        # use a better solution later
        fake_idx = idx * num_dev + i_dev
        get(updater)(fake_idx, self.grad_arrays[idx][i_dev], self.param_arrays[idx][i_dev])
      end
    end
  end
end

"""
    get_params!(self, arg_params, aux_params)

Copy data from each executor to `arg_params` and `aux_params`.
# Arguments
* `arg_params` : Dict{Symbol, Vector{NDArray}}. Target parameter arrays
* `aux_params` : Dict{Symbol, Vector{NDArray}}. Target aux arrays

# Notes
This function will inplace update the NDArrays in arg_params and aux_params.
"""
function get_params!(self::DataParallelExecutorGroup, arg_params::Dict{Symbol, NDArray},
                    aux_params::Dict{Symbol, NDArray})
  for (name, block) in zip(self.param_names, self.param_arrays)
    w = empty(size(block[1]))
    for i in 1:length(block)
      @inplace w .+= copy(block[i], cpu())
    end
    @inplace w ./= length(block)
    copy!(arg_params[name], w)
  end
  for (name, block) in zip(self.aux_names, self.aux_arrays)
    w = empty(size(block[1]))
    for i in 1:length(block)
      @inplace w .+= copy(block[i], cpu())
    end
    @inplace w ./= length(block)
    copy!(aux_params[name], w)
  end
end

"""
    update_metric

Accumulate the performance according to `eval_metric` on all devices.
# Parameters
* eval_metric : EvalMetric
	The metric used for evaluation.
* labels : list of NDArray
	Typically comes from `label` of a `DataBatch`.
"""
function update_metric(self::DataParallelExecutorGroup, eval_metric::AbstractEvalMetric, provider::AbstractDataProvider, batch::AbstractDataBatch)

  # XXX: there is a possibility, that label arrays lie in different
  # context than cpu_output_arrays. It should be checked and labels
  # should be copied to corresponding context
  cpu_output_arrays = get_outputs(self)
  update!(eval_metric, get_label(provider, batch), cpu_output_arrays)
end

"""
		get_outputs

Get outputs of the previous forward computation.

# Arguments
merge_multi_context : Bool
Default is `True`. In the case when data-parallelism is used, the outputs
will be collected from multiple devices. A `True` value indicate that we
should merge the collected results so that they look like from a single
executor.
# Returns
If `merge_multi_context` is `true`, it is like `[out1, out2]`. Otherwise, it
is like `[[out1_dev1, out1_dev2], [out2_dev1, out2_dev2]]`. All the output
elements are `NDArray`.
"""
function get_outputs(self::DataParallelExecutorGroup, merge_multi_context::Bool=true)
  outputs = [[exec.outputs[i] for exec in self.execs] for i in 1:length(self.execs[1].outputs)]

  if merge_multi_context
    # TODO In original FeedForward model single predefined
    # output was used. _merge_multi_context creates new array
    # each time it is called. Need to benchmark, may be it's better
    # to predefine cpu_output_arrays in self.
    return [concatenate(tensors, always_copy=false) for tensors in outputs]
  else
    return outputs
  end
end

"""
    get_input_grads(self, merge_multi_context)

Get the gradients with respect to the inputs of the module.

# Arguments
* `merge_multi_context` : `Bool`
  Default is `true`. In the case when data-parallelism is used, the outputs
  will be collected from multiple devices. A `true` value indicate that we
  should merge the collected results so that they look like from a single
  executor.

# Returns
If `merge_multi_context` is `True`, it is like `[grad1, grad2]`. Otherwise, it
is like `[[grad1_dev1, grad1_dev2], [grad2_dev1, grad2_dev2]]`. All the output
elements are `NDArray`.
"""
function get_input_grads(self::DataParallelExecutorGroup, merge_multi_context::Bool=true)
  !self.inputs_need_grad && NDArray[]

  if merge_multi_context
    return [concatenate(tensors, always_copy=false) for tensors in self.input_grad_arrays]
  end

  return self.input_grad_arrays
end

function output_shapes(self:: DataParallelExecutorGroup)
  outputs = [size(out) for out in self.execs[1].outputs]
  return Dict(key => shape for (key, shape) in zip(list_outputs(self.symbol), outputs))
end

##
# Internals
##

function get_grads(symbol, param_names, arg_names, data_names, inputs_need_grad, fixed_param_names, grad_req)
  if isnull(fixed_param_names)
    # get grad attribute to allow for freezing
    fixed_param_names = Symbol[]
    for (attr, value) in list_all_attr(symbol)
      sattr = string(attr)
      if endswith(sattr, "grad") && value == "freeze"
        push!(fixed_param_names, Symbol(sattr[1:end-5]))
      end
    end
  else
    fixed_param_names = get(fixed_param_names)
  end

  # Needs to correspond to the correct id in the update loop layer idx=1:length(param_names).
  freeze_idx = filter(i -> in(param_names[i], fixed_param_names), 1:length(param_names))

  # Setup grad_req as a dictionary
  grad_req_dict = Dict{Symbol, GRAD_REQ}()
  for param in arg_names
    if param in param_names
      if in(param, fixed_param_names)
        grad_req_dict[param] = GRAD_NOP
      else
        grad_req_dict[param] = grad_req
      end
    elseif param in data_names
      if inputs_need_grad
        grad_req_dict[param] = grad_req
      else
        grad_req_dict[param] = GRAD_NOP
      end
    else
      grad_req_dict[param] = GRAD_NOP
    end
  end

  return grad_req_dict, freeze_idx
end
