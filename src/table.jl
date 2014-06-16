

# A special kind of container promise that performs table layout optimization.

type Table <: ContainerPromise
    # Direct children must be Contexts, and not just Containers.
    children::Matrix{Vector{Context}}

    # In the formulation of the table layout problem used here, we are trying
    # find a feasible solution in which the width + height of a particular
    # group of cells in the table is maximized.
    x_focus::Range1{Int}
    y_focus::Range1{Int}

    # If non-nothing, constrain the focused cells to have a proportional
    # relationship.
    x_prop::Union(Nothing, Vector{Float64})
    y_prop::Union(Nothing, Vector{Float64})

    # Coordinate system used for children
    units::UnitBox

    # Z-order of this context relative to its siblings.
    order::Int

    # Ignore this context and everything under it if we are
    # not drawing to the javascript backend.
    withjs::Bool

    # Igonre this context if we are drawing to the SVGJS backend.
    withoutjs::Bool


    function Table(m::Integer, n::Integer,
                   x_focus::Range1{Int}, y_focus::Range1{Int};
                   x_prop=nothing, y_prop=nothing,
                   units=UnitBox(), order=0, withjs=false, withoutjs=false)

        if x_prop != nothing
            @assert length(x_prop) == length(x_focus)
            x_prop ./= sum(x_prop)
        end


        if y_prop != nothing
            @assert length(y_prop) == length(y_focus)
            y_prop ./= sum(y_prop)
        end

        tbl = new(Array(Vector{Context}, (m, n)),
                  x_focus, y_focus,
                  x_prop, y_prop,
                  units, order, withjs, withoutjs)
        for i in 1:m, j in 1:n
            tbl.children[i, j] = Array(Context, 0)
        end
        return tbl
    end
end

const table = Table


function getindex(t::Table, i::Integer, j::Integer)
    return t.children[i, j]
end


function setindex!(t::Table, child, i::Integer, j::Integer)
    t.children[i, j] = child
end


# Solve the table layout using a brute force approach, when a MILP isn't
# available.
function realize_brute_force(tbl::Table, drawctx::ParentDrawContext)

    # Iterate through every combination of children.
    choices = [length(child) > 1 ? (1:length(child)) : [0]
               for child in tbl.children]

    m, n = size(tbl.children)

    maxobjective = 0.0
    optimal_choice = nothing
    feasible = false # is the current optimal_choice feasible

    # if the current solution is infeasible, we try to minimize badness,
    # which is basically "size needed" - "size available".
    minbadness = Inf

    focused_col_widths = Array(Float64, length(tbl.x_focus))
    focused_row_heights = Array(Float64, length(tbl.y_focus))

    # minimum sizes for each column and row
    minrowheights = Array(Float64, m)
    mincolwidths = Array(Float64, n)

    # compute the optimal column widths/row heights for fixed choice and
    # pre-computed minrowheight/mincolwidths.
    function update_focused_col_widths!(focused_col_widths)
        minwidth = sum(mincolwidths)
        total_focus_width =
            drawctx.box.width - minwidth + sum(mincolwidths[tbl.x_focus])

        if tbl.x_prop != nothing
            for k in 1:length(tbl.x_focus)
                focused_col_widths[k] = tbl.x_prop[k] * total_focus_width
            end
        else
            extra_width = total_focus_width - sum(mincolwidths[tbl.x_focus])
            for k in 1:length(tbl.x_focus)
                focused_col_widths[k] =
                    mincolwidths[tbl.x_focus[k]] + extra_width / length(tbl.x_focus)
            end
        end
    end

    function update_focused_row_heights!(focused_row_heights)
        minheight = sum(minrowheights)
        total_focus_height =
            drawctx.box.height - minheight + sum(minrowheights[tbl.y_focus])

        if tbl.y_prop != nothing
            for k in 1:length(tbl.y_focus)
                focused_row_heights[k] = tbl.y_prop[k] * total_focus_height
            end
        else
            extra_height = total_focus_height - sum(minrowheights[tbl.y_focus])
            for k in 1:length(tbl.y_focus)
                focused_row_heights[k] =
                    minrowheights[tbl.y_focus[k]] + extra_height / length(tbl.y_focus)
            end
        end
    end

    # fora given configuration, compute the minimum width for every column and
    # minimum height for every row.
    function update_mincolrow_sizes!(choice, minrowheights, mincolwidths)
        fill!(minrowheights, Inf)
        fill!(mincolwidths, Inf)
        for i in 1:m, j in 1:n
            if isempty(tbl.children[i, j])
                continue
            end

            choice_ij = choice[(j-1)*m + i]
            child = tbl.children[i, j][(choice_ij == 0 ? 1 : choice_ij)]
            mw, mh = minwidth(child), minheight(child)
            if mw != nothing && mw < mincolwidths[j]
                mincolwidths[j] = mw
            end
            if mh != nothing && mh < minrowheights[i]
                minrowheights[i] = mh
            end
        end

        minrowheights[!isfinite(minrowheights)] = 0.0
        mincolwidths[!isfinite(mincolwidths)] = 0.0
    end

    for choice in product(choices...)
        update_mincolrow_sizes!(choice, minrowheights, mincolwidths)

        minheight = sum(minrowheights)
        minwidth = sum(mincolwidths)

        update_focused_col_widths!(focused_col_widths)
        update_focused_row_heights!(focused_row_heights)

        objective = sum(focused_col_widths) + sum(focused_row_heights)

        # feasible?
        if minwidth < drawctx.box.width && minheight < drawctx.box.height &&
           all(focused_col_widths .>= mincolwidths[tbl.x_focus]) &&
           all(focused_row_heights .>= minrowheights[tbl.y_focus])
            if objective > maxobjective || !feasible
                maxobjective = objective
                minbadness = 0.0
                optimal_choice = choice
            end
            feasible = true
        else
            badness = max(minwidth - drawctx.box.width, 0.0) +
                      max(minheight - drawctx.box.height, 0.0)
            if badness < minbadness && !feasible
                minbadness = badness
                optimal_choice = choice
            end
        end
    end

    if !feasible
        warn("Graphic cannot be correctly drawn at the given size.")
    end

    update_mincolrow_sizes!(optimal_choice, minrowheights, mincolwidths)
    update_focused_col_widths!(focused_col_widths)
    update_focused_row_heights!(focused_row_heights)

    w_solution = mincolwidths
    h_solution = minrowheights

    for k in 1:length(tbl.x_focus)
        w_solution[tbl.x_focus[k]] = focused_col_widths[k]
    end

    for k in 1:length(tbl.y_focus)
        h_solution[tbl.y_focus[k]] = focused_row_heights[k]
    end

    x_solution = cumsum(mincolwidths)
    y_solution = cumsum(minrowheights)

    root = context(units=tbl.units, order=tbl.order)

    for i in 1:m, j in 1:n
        if isempty(tbl.children[i, j])
            continue
        elseif length(tbl.children[i, j]) == 1
            ctx = copy(tbl.children[i, j][1])
        elseif length(tbl.children[i, j]) > 1
            idx = optimal_choice[(j-1)*m + i]
            ctx = copy(tbl.children[i, j][idx])
        end
        ctx.box = BoundingBox(
            (x_solution[j] - w_solution[j])*mm,
            (y_solution[i] - h_solution[i])*mm,
            w_solution[j]*mm, h_solution[i]*mm)
        compose!(root, ctx)
    end

    return root
end



if Pkg.installed("JuMP") != nothing &&
    (Pkg.installed("GLPKMathProgInterface") != nothing ||
     Pkg.installed("Cbc") != nothing)
    using JuMP

    function is_approx_integer(x::Float64)
        return abs(x - round(x)) < 1e-8
    end

    function realize(tbl::Table, drawctx::ParentDrawContext)
        model = Model()

        m, n = size(tbl.children)

        abswidth = drawctx.box.width
        absheight = drawctx.box.height

        c_indexes = {}
        for i in 1:m, j in 1:n
            if length(tbl.children[i, j]) > 1
                for k in 1:length(tbl.children[i, j])
                    push!(c_indexes, (i, j, k))
                end
            end
        end

        # 0-1 configuration variables for every cell with multiple configurations
        @defVar(model, c[1:length(c_indexes)], Bin)

        # width for every column
        @defVar(model, 0 <= w[1:n] <= abswidth)

        # height for every row
        @defVar(model, 0 <= h[1:m] <= absheight)

        # maximize the "size" of the focused cells
        @setObjective(model, Max, sum{w[j], j=tbl.x_focus} +
                                  sum{h[i], i=tbl.y_focus})

        # optional proportionality contraints
        if tbl.x_prop != nothing
            # TODO: there's probably a less barbaric way of doing this
            for k in 2:length(tbl.x_focus)
                j1 = tbl.x_focus[1]
                jk = tbl.x_focus[k]
                @addConstraint(model, w[j1] / tbl.x_prop[1] ==  w[jk] / tbl.x_prop[k])
            end
        end

        if tbl.y_prop != nothing
            for k in 2:length(tbl.y_focus)
                i1 = tbl.y_focus[1]
                ik = tbl.y_focus[k]
                @addConstraint(model, h[i1] / tbl.y_prop[1] ==  h[ik] / tbl.y_prop[k])
            end
        end

        # configurations are mutually exclusive
        for cgroup in groupby(1:length(c_indexes),
                              l -> (c_indexes[l][1], c_indexes[l][2]))
            @addConstraint(model, sum{c[l], l=cgroup} == 1)
        end

        # minimum cell size contraints for cells with multiple configurations
        for (l, (i, j, k)) in enumerate(c_indexes)
            minw = minwidth(tbl.children[i, j][k])
            minh = minheight(tbl.children[i, j][k])
            if minw != nothing
                @addConstraint(model, w[j] >= minw * c[l])
            end

            if minh != nothing
                @addConstraint(model, h[i] >= minh * c[l])
            end
        end

        # minimum cell size constraint for fixed cells
        for i in 1:m, j in 1:n
            if length(tbl.children[i, j]) == 1
                minw = minwidth(tbl.children[i, j][1])
                minh = minheight(tbl.children[i, j][1])
                if minw != nothing
                    @addConstraint(model, w[j] >= minw)
                end
                if minh != nothing
                    @addConstraint(model, h[i] >= minh)
                end
            end
        end

        # widths and heights must add up
        @addConstraint(model, sum{w[i], i=1:n} == abswidth)
        @addConstraint(model, sum{h[i], i=1:m} == absheight)

        status = solve(model)

        w_solution = getValue(w)
        h_solution = getValue(h)
        c_solution = getValue(c)

        if status == :Infeasible || !all([is_approx_integer(c_solution[l])
                                          for l in 1:length(c_indexes)])
            # TODO: this warning is just for debugging.
            println(STDERR, "JuMP: Infeasible")
            # The brute force solver is better able to select between various
            # non-feasible solutions. So we let it have a go.
            return realize_brute_force(tbl, drawctx)
        end

        # Set positions and sizes of children
        root = context(units=tbl.units, order=tbl.order)

        x_solution = cumsum([w_solution[j] for j in 1:n])
        y_solution = cumsum([h_solution[i] for i in 1:m])

        # set child positions according to layout solution
        for i in 1:m, j in 1:n
            if length(tbl.children[i, j]) == 1
                ctx = copy(tbl.children[i, j][1])
                ctx.box = BoundingBox(
                    (x_solution[j] - w_solution[j])*mm,
                    (y_solution[i] - h_solution[i])*mm,
                    w_solution[j]*mm, h_solution[i]*mm)
                compose!(root, ctx)
            end
        end

        for (l, (i, j, k)) in enumerate(c_indexes)
            if round(c_solution[l]) == 1
                ctx = copy(tbl.children[i, j][k])
                ctx.box = BoundingBox(
                    (x_solution[j] - w_solution[j])*mm,
                    (y_solution[i] - h_solution[i])*mm,
                    w_solution[j]*mm, h_solution[i]*mm)
                compose!(root, ctx)
            end
        end

        return root
    end
else
    function realize(tbl::Table, drawctx::ParentDrawContext)
        return realize_brute_force(tbl, drawctx)
    end
end
