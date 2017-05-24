# this file contains code used for enabling backward compatibility with 0.5

if VERSION < v"0.6.0-dev"
    macro chain(layers)
      exprs = []
      last_layer = nothing
      function _chain_layer(layer, last_layer)
        if isa(last_layer, Void)
          esc(layer)
        else
          @assert(isa(layer, Expr) && layer.head == :call, "Do not know how to chain up $layer")
          return Expr(:call, esc(layer.args[1]), last_layer, map(esc, layer.args[2:end])...)
        end
      end
      while true
        if layers.head == :(=>)
          new_layer = gensym()
          push!(exprs, :($new_layer = $(_chain_layer(layers.args[1], last_layer))))
          last_layer = new_layer
          layers = layers.args[2]
        else
          push!(exprs, _chain_layer(layers, last_layer))
          break
        end
      end
      return Expr(:block, exprs...)
    end
end


# this is for declaring broadcasted functions in 0.5
# TODO this macro should be removed when 0.5 support is dropped
macro compatdot(fblock)
    if VERSION ≥ v"0.6.0-dev"
        return esc(fblock)
    end
    @capture(fblock, function Base.broadcast(::typeof(op_), args__)
                        body_
                     end)
    opdot = Symbol(string('.',op))
    esc(quote
        function $opdot($(args...))
            $body
        end
    end)
end
