using CSV
using DataFrames

##############################
# Set data directories
##############################
data_dir = joinpath(dirname(@__DIR__), "data")
tmp_data_dir = joinpath(dirname(@__DIR__), "data_tmp")

#################################
# Read uncertain scaling factors
#################################
function read_scaling_factors(scenario)
    # Get uncertain factors
    DU_f = Matrix(CSV.read("$(tmp_data_dir)/DU_factors_v3_300.csv", DataFrame, header=false))
    DU_f = DU_f[sortperm(DU_f[:, 7]), :] # sort by 7th column = CC scenario number

    if scenario == 0
        # bd_rateAE = 0.92
        # bd_rateFI = 0.92
        # bd_rateJK = 0.92
        # ev_rateAE = 0.9
        # ev_rateFI = 0.9
        # ev_rateJK = 0.9
        bd_rate = 0.92
        ev_rate = 0.9
        wind_scalar = 1
        solar_scalar = 1
        batt_scalar = 1
    else
        cc_scenario = string(Int(DU_f[scenario, 7]))

        bd_rate = DU_f[scenario, 2]
        # bd_rateAE = bd_rate
        # bd_rateFI = bd_rate
        # bd_rateJK = bd_rate

        ev_rate = DU_f[scenario, 3]
        # ev_rateAE = ev_rate
        # ev_rateFI = ev_rate
        # ev_rateJK = ev_rate

        wind_scalar = DU_f[scenario, 4]
        solar_scalar = DU_f[scenario, 5]
        batt_scalar = DU_f[scenario, 6]
    end

    return cc_scenario, bd_rate, ev_rate, wind_scalar, solar_scalar, batt_scalar
end

##############################
# Grid
##############################
function get_if_lims(year, n_if_lims, nt=8760)
    """
    Read interface limit information
    """
    if_scenario = 0 # DIFFERENT FROM MAIN??

    if_lim_up = Matrix(CSV.read("$(tmp_data_dir)/Iflim/iflimup_$(year)_$(if_scenario).csv", DataFrame, header=false))
    @assert size(if_lim_up, 2) == nt "Upper interface limits is incorrect size"
    @assert size(if_lim_up, 1) == n_if_lims "Upper interface limits is incorrect size"

    if_lim_dn = Matrix(CSV.read("$(tmp_data_dir)/Iflim/iflimdn_$(year)_$(if_scenario).csv", DataFrame, header=false))
    @assert size(if_lim_dn, 2) == nt "Lower interface limits is incorrect size"
    @assert size(if_lim_dn, 1) == n_if_lims "Lower interface limits is incorrect size"

    if_lim_map = Matrix(CSV.read("$(data_dir)/nyiso/interface_limits/if_lim_map.csv", DataFrame, header=true))

    if_lim_up[9, :] .= if_lim_up[9, :] ./ 8750 .* 8450 # ?????

    return if_lim_up, if_lim_dn, if_lim_map
end

function get_storage(batt_scalar, batt_duration, nt=8760)
    storage = Matrix(CSV.read("$(tmp_data_dir)/StorageData/StorageAssignment.csv", DataFrame, header=false))
    storage_bus_ids = Int.(storage[:, 1])
    batt_cap = Matrix(storage[:, 1:end])

    charge_cap = batt_scalar .* repeat(batt_cap[:, 2], 1, nt)
    storage_cap = batt_scalar .* batt_duration .* repeat(batt_cap[1:end-1, 2], 1, nt + 1)
    storage_cap = vcat(storage_cap, batt_scalar * 12 * repeat(batt_cap[end:end, 2], 1, nt + 1))  # Adjust for last storage

    return charge_cap, storage_cap, storage_bus_ids
end

##############################
# Load
##############################
function get_load(cc_scenario, year, ev_rate, bd_rate, bus_ids, nt=8760)
    """
    Reads and sums the four kinds of load (base, commerical, residential, EV)

    NOTE:
    - In the original code, the building and EV loads can be scaled by zone-specific rates; this is simplified here

    """
    # Base load
    base_load = Matrix(CSV.read("$(tmp_data_dir)/load/BaseLoad/Scenario$(cc_scenario)/simload_$(year).csv", DataFrame, header=false))
    # base_load = hcat(bus_ids, base_load) # prepend bus_ids (UPDATE THIS!)
    @assert size(base_load, 2) == nt "Base load is incorrect size"

    # EV load, only for certain buses
    ev_load = Matrix(CSV.read("$(tmp_data_dir)/load/EVload/EVload_Bus.csv", DataFrame, header=false))
    @assert size(ev_load, 2) == nt + 1 "EV load is incorrect size"
    ev_load_bus_id = ev_load[:, 1]

    # Residential load, for certain buses
    res_load = Matrix(CSV.read("$(tmp_data_dir)/load/ResLoad/Scenario$(cc_scenario)/ResLoad_Bus_$(year).csv", DataFrame, header=false))
    @assert size(res_load, 2) == nt + 1 "Residential load is incorrect size"
    res_load_bus_id = res_load[:, 1]

    # Commerical load, for certain buses
    com_load = Matrix(CSV.read("$(tmp_data_dir)/load/ComLoad/Scenario$(cc_scenario)/ComLoad_Bus_$(year).csv", DataFrame, header=false))
    @assert size(com_load, 2) == nt + 1 "Commercial load is incorrect size"
    com_load_bus_id = com_load[:, 1]

    # Total load
    total_load = copy(base_load)

    # Add EV load
    for i in eachindex(ev_load_bus_id)
        bus_idx = findfirst(==(ev_load_bus_id[i]), bus_ids)
        total_load[bus_idx, :] .+= (ev_load[i, 2:end] .* ev_rate)
    end

    # Add residential load
    for i in eachindex(res_load_bus_id)
        bus_idx = findfirst(==(res_load_bus_id[i]), bus_ids)
        total_load[bus_idx, :] .+= (res_load[i, 2:end] .* bd_rate)
    end

    # Add commercial load
    for i in eachindex(com_load_bus_id)
        bus_idx = findfirst(==(com_load_bus_id[i]), bus_ids)
        total_load[bus_idx, :] .+= (com_load[i, 2:end] .* bd_rate)
    end

    return total_load
end

function subtract_solar_dpv(load_in, bus_ids, cc_scenario, year, solar_scalar, nt=8760)
    """
    Adjusts the load data by subtracting behind-the-meter solar (SolarDPV)
    """
    load = copy(load_in)

    # Load renewable generation data: only for certain buses so record those bus ids
    solar_dpv = Matrix(CSV.read("$(tmp_data_dir)/gen/Solar/Scenario$(cc_scenario)/solarDPV$(year).csv", DataFrame, header=false))
    @assert size(solar_dpv, 2) == nt + 1 "Solar DPV is incorrect size"
    solar_dpv_bus_ids = Int.(solar_dpv[:, 1])

    # Adjust loads with behind-the-meter solar
    for i in eachindex(solar_dpv_bus_ids)
        bus_idx = findfirst(==(solar_dpv_bus_ids[i]), bus_ids)
        load[bus_idx, :] .-= (solar_dpv[i, 2:end] .* solar_scalar)
    end

    return load
end

function subtract_small_hydro(load_in, bus_ids, nt=8760)
    """
    Adjusts the load data by subtracting small hydro generation
    """
    load = copy(load_in)

    # Read small hydro
    small_hydro_gen = Matrix(CSV.read("$(tmp_data_dir)/hydrodata/smallhydrogen.csv", DataFrame, header=false))
    @assert size(small_hydro_gen, 2) == nt "Small hydro generation is incorrect size"
    # Read small hydro bus ids (UPDATE THIS!!)
    small_hydro_bus_id = CSV.read("$(tmp_data_dir)/hydrodata/SmallHydroCapacity.csv", DataFrame)[!, "bus index"]

    # Subtract from existing load
    for i in eachindex(small_hydro_bus_id)
        bus_idx = findfirst(==(small_hydro_bus_id[i]), bus_ids)
        load[bus_idx, :] .-= small_hydro_gen[i, :]
    end

    return load
end

############################################################
# Generation
############################################################
function get_solar_upv(cc_scenario, year, solar_scalar, nt=8760)
    """
    Read solar generationd data
    """
    # SolarUPV generation data
    solar_upv = CSV.read("$(tmp_data_dir)/gen/Solar/Scenario$(cc_scenario)/solarUPV$(year).csv", DataFrame, header=false)
    @assert size(solar_upv, 2) == nt + 1 "Solar UPV is incorrect size"
    solar_upv_bus_ids = Int.(solar_upv[:, 1])
    solar_upv_gen = Matrix(solar_upv[:, 1:end]) .* solar_scalar
    return solar_upv_gen, solar_upv_bus_ids
end

function get_wind(year, wind_scalar, nt=8760)
    """
    Read solar generationd data
    """
    # Wind generation data
    wind = CSV.read("$(tmp_data_dir)/gen/Wind/Wind$(year).csv", DataFrame, header=false)
    @assert size(wind, 2) == nt + 1 "Wind is incorrect size"
    wind_bus_ids = Int.(wind[:, 1])
    wind_gen = Matrix(wind[:, 1:end]) .* wind_scalar
    return wind_gen, wind_bus_ids
end

function add_upv_generators(gen_prop, solar_bus_ids)
    # Solar generator info
    solar = similar(gen_prop, length(solar_bus_ids))

    solar[:, 1] .= solar_bus_ids # Bus number
    solar[:, 2] .= 0 # Pg
    solar[:, 3] .= 0 # Qg
    solar[:, 4] .= 9999 # Qmax
    solar[:, 5] .= -9999 # Qmin
    solar[:, 6] .= 1 # Vg
    solar[:, 7] .= 100 # mBase
    solar[:, 8] .= 1 # status
    solar[:, 9] .= 0 # Pmax
    solar[:, 10] .= 0 # Pmin
    solar[:, 11] .= 0 # Pc1
    solar[:, 12] .= 0 # Pc2
    solar[:, 13] .= 0 # Qc1min
    solar[:, 14] .= 0 # Qc1max
    solar[:, 15] .= 0 # Qc2min
    solar[:, 16] .= 0 # Qc2max
    solar[:, 17] .= Inf # ramp rate for load following/AGC
    solar[:, 18] .= Inf # ramp rate for 10 minute reserves
    solar[:, 19] .= Inf # ramp rate for 30 minute reserves
    solar[:, 20] .= 0 # ramp rate for reactive power
    solar[:, 21] .= 0 # area participation factor
    solar[:, 22] .= "SolarUPV" # generation type

    # Append to gen_prop
    return vcat(gen_prop, solar)
end

function add_wind_generators(gen_prop, wind_bus_ids)
    # Wind generator info
    wind = similar(gen_prop, length(wind_bus_ids))

    wind[:, 1] .= wind_bus_ids # Bus number
    wind[:, 2] .= 0 # Pg
    wind[:, 3] .= 0 # Qg
    wind[:, 4] .= 9999 # Qmax
    wind[:, 5] .= -9999 # Qmin
    wind[:, 6] .= 1 # Vg
    wind[:, 7] .= 100 # mBase
    wind[:, 8] .= 1 # status
    wind[:, 9] .= 0 # Pmax
    wind[:, 10] .= 0 # Pmin
    wind[:, 11] .= 0 # Pc1
    wind[:, 12] .= 0 # Pc2
    wind[:, 13] .= 0 # Qc1min
    wind[:, 14] .= 0 # Qc1max
    wind[:, 15] .= 0 # Qc2min
    wind[:, 16] .= 0 # Qc2max
    wind[:, 17] .= Inf # ramp rate for load following/AGC
    wind[:, 18] .= Inf # ramp rate for 10 minute reserves
    wind[:, 19] .= Inf # ramp rate for 30 minute reserves
    wind[:, 20] .= 0 # ramp rate for reactive power
    wind[:, 21] .= 0 # area participation factor
    wind[:, 22] .= "Wind" # generation type

    # Append to gen_prop
    return vcat(gen_prop, wind)
end

function get_hydro(cc_scenario, year)
    # Robert-Moses Niagra hydro production, quarter monthly
    niagra_hydro = CSV.read("$(tmp_data_dir)/hydrodata/nypaNiagaraEnergy.climate.change.csv", DataFrame)

    #  Moses-SaundersPower Dam production, quarter monthly
    moses_saund_hydro = CSV.read("$(tmp_data_dir)/hydrodata/nypaMosesSaundersEnergy.climate.change.csv", DataFrame)

    # Select appropriate year and baseline scenario
    if cc_scenario != 0
        colname1 = Symbol("nypaNiagaraEnergy.$(cc_scenario)")
        colname2 = Symbol("nypaMosesSaundersEnergy.$(cc_scenario)")
    else
        colname1 = :nypaNiagaraEnergy
        colname2 = :nypaMosesSaundersEnergy
    end

    niagra_hydro = niagra_hydro[niagra_hydro.Year.==year, colname1]
    moses_saund_hydro = moses_saund_hydro[moses_saund_hydro.Year.==year, colname2]

    return niagra_hydro, moses_saund_hydro
end