module EditingFixture
    #= Outer comment, with "quotes" and function/end.
       #= Nested comment =#
       Still the outer comment.
    =#
    abstract type Animal end
    primitive type Byte 8 end
    mutable struct Box{T}
        value::T
    end

    """Unicode α and 🦦; literal "quotes" and interpolation $(1 + 2)."""
    function greet!(α, β)
        message = "hello $(α), $β"
        rawtext = raw"no interpolation $α"
        letter = 'λ'
        newline = '\n'
        apostrophe = '\''
        transpose = α'
        chained = [1 2; 3 4]'
        @show message
        if α > 0
            for x in β
                while x > 1
                    x -= 1
                end
            end
        elseif α == 0
            nothing
        else
            missing
        end
        try
            sin(α)
        catch err
            @warn "failed" err
        finally
            println("done")
        end
        return message
    end

    short(α)::Int where T = α + 1
    Base.show(io::IO, box::Box) = print(io, box.value)
    macro reveal(x)
        quote
            $(esc(x))
        end
    end
    values = map([1, 2]) do x
        x + 1
    end
    let x = 1
        begin
            x + 1
        end
    end
    call = greet!(
        1,
        [2, 3]
    )
end
