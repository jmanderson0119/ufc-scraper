using PyCall
using Gumbo
using ArgParse  # For command-line argument parsing

# pre-allocate all python imports at the beginning
const webdriver = PyNULL()
const webdriver_manager = PyNULL()
const service = PyNULL()
const options = PyNULL()
const by = PyNULL()
const wait = PyNULL()
const expected_conditions = PyNULL()

function __init__()
    copy!(webdriver, pyimport("selenium.webdriver"))
    copy!(webdriver_manager, pyimport("webdriver_manager.chrome"))
    copy!(service, pyimport("selenium.webdriver.chrome.service"))
    copy!(options, pyimport("selenium.webdriver.chrome.options"))
    copy!(by, pyimport("selenium.webdriver.common.by").By)
    copy!(wait, pyimport("selenium.webdriver.support.wait"))
    copy!(expected_conditions, pyimport("selenium.webdriver.support.expected_conditions"))
end

# constants for faster lookup
const MONTH_MAP = Dict("January" => "01", "February" => "02", "March" => "03", "April" => "04", 
                      "May" => "05", "June" => "06", "July" => "07", "August" => "08", 
                      "September" => "09", "October" => "10", "November" => "11", "December" => "12")

# Win methods to exclude
const EXCLUDED_WIN_METHODS = [
    "DQ", "Disqualification", "Overturned", 
    "No Contest", "NC", "Could Not Continue",
    "Decision - Majority", "Decision - Split", "Other"
]

# optimized helper functions with type annotations
function convert_date(date_ls::Vector{SubString{String}})::Int
    return parse(Int, join([date_ls[4], MONTH_MAP[date_ls[2]], date_ls[3]], ""))
end

function get_year_from_date(date_int::Int)::Int
    return div(date_int, 10000)
end

function convert_to_seconds(match_duration::Vector{SubString{String}})::Int
    return parse(Int, match_duration[1]) * 60 + parse(Int, match_duration[2])
end

function clean_result_data(contest_results_elem, elem)::String
    return strip(string(text(contest_results_elem[elem][2])), [' ', '\n'])
end

function should_exclude_win_method(win_method::String)::Bool
    if isempty(win_method)
        return false
    end
    normalized_method = strip(win_method)
    for method in EXCLUDED_WIN_METHODS
        if occursin(lowercase(method), lowercase(normalized_method))
            return true
        end
    end
    return false
end

function reformat_contest_data(contest_fighter_bout_info, contest_results, 
                              contest_totals_fighter1, contest_totals_fighter2, 
                              sig_str_totals_fighter1, sig_str_totals_fighter2)
    # contest fighter bout information
    date = contest_fighter_bout_info[1]
    weight_class = contest_fighter_bout_info[2]
    fighter1_result = contest_fighter_bout_info[3]
    fighter1_name = contest_fighter_bout_info[4]
    fighter2_result = contest_fighter_bout_info[5]
    fighter2_name = contest_fighter_bout_info[6]
    
    # contest results information
    win_method = contest_results[1]
    match_duration = contest_results[2]
    time_format = contest_results[3]
    
    # pre-allocate arrays with correct size
    fighter1_data = Vector{Any}(undef, 25)
    fighter2_data = Vector{Any}(undef, 25)
    
    # faster direct assignment instead of push!
    fighter1_data[1:7] = [date, weight_class, fighter1_name, fighter1_result, win_method, match_duration, time_format]
    fighter1_data[8:13] = contest_totals_fighter1
    fighter1_data[14:25] = sig_str_totals_fighter1
    
    fighter2_data[1:7] = [date, weight_class, fighter2_name, fighter2_result, win_method, match_duration, time_format]
    fighter2_data[8:13] = contest_totals_fighter2
    fighter2_data[14:25] = sig_str_totals_fighter2
    
    return fighter1_data, fighter2_data
end

# optimized file i/o
function save_to_csv(data, header, filename)
    open(filename, "w") do io
        println(io, join(header, ","))
        
        for row in data
            # pre-allocate the string array for join
            row_str = Array{String}(undef, length(row))
            for i in eachindex(row)
                row_str[i] = string(row[i])
            end
            println(io, join(row_str, ","))
        end
    end
end

# Save benchmark file
function save_benchmark(data, header, basename, benchmark_num)
    benchmark_file = "$(splitext(basename)[1])_benchmark_$(benchmark_num).csv"
    println("Saving benchmark file $benchmark_file with $(length(data)) records")
    save_to_csv(data, header, benchmark_file)
    println("Benchmark $benchmark_num saved successfully")
end

# reusable function to create chrome driver with options
function create_chrome_driver()
    chrome_options = options.Options()
    chrome_options.add_argument("--headless")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")
    # add performance options
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-dev-tools")
    chrome_options.add_argument("--disable-infobars")
    chrome_options.add_argument("--disable-notifications")
    chrome_options.add_argument("--disable-popup-blocking")
    
    chrome_driver_path = webdriver_manager.ChromeDriverManager().install()
    chrome_service = service.Service(chrome_driver_path)
    
    return webdriver.Chrome(service=chrome_service, options=chrome_options)
end

function scrape_contest(contest_url, start_year, end_year)
    driver = create_chrome_driver()

    try
        driver.get(contest_url)

        # define wait object once
        wait_obj = wait.WebDriverWait(driver, 10)
        wait_obj.until(expected_conditions.presence_of_element_located((by.CLASS_NAME, "b-fight-details")))

        # parse html only once
        html_content = driver.page_source
        parsed_html = parsehtml(html_content)

        # pre-allocate arrays
        contest_fighter_bout_info = Vector{Any}(undef, 6)
        contest_results = Vector{Any}(undef, 3)
        contest_totals_fighter1 = Vector{Int}(undef, 6)
        contest_totals_fighter2 = Vector{Int}(undef, 6)
        sig_str_totals_fighter1 = Vector{Int}(undef, 12)
        sig_str_totals_fighter2 = Vector{Int}(undef, 12)
        
        # scrape fighter-bout information
        contest_fighter_info = parsed_html.root[2][2][1][2][1]
        
        # get event date
        event_date_elem = driver.find_element(by.CLASS_NAME, "b-list__box-list-item")
        event_date_text = event_date_elem.text
        event_date = convert_date(split(replace(event_date_text, "," => ""), " "))
        
        # Check if date is within range
        year = get_year_from_date(event_date)
        if year < start_year || year > end_year
            println("Skipping fight from year $year (outside range $start_year-$end_year)")
            return nothing
        end
        
        # store values directly in pre-allocated array
        contest_fighter_bout_info[1] = event_date
        
        bout_info = parsed_html.root[2][2][1][2][2][1][1]
        contest_fighter_bout_info[2] = strip(replace(string(text(bout_info)), "UFC" => "", "Title" => "", "Bout" => ""))
        contest_fighter_bout_info[3] = string(text(contest_fighter_info[1][1]))
        contest_fighter_bout_info[4] = string(text(contest_fighter_info[1][2][1][1]))
        contest_fighter_bout_info[5] = string(text(contest_fighter_info[2][1]))
        contest_fighter_bout_info[6] = string(text(contest_fighter_info[2][2][1][1]))

        # Log the fighter info for debugging
        println("Fight: $(contest_fighter_bout_info[4]) ($(contest_fighter_bout_info[3])) vs $(contest_fighter_bout_info[6]) ($(contest_fighter_bout_info[5]))")

        # scrape contest results
        contest_outcomes = parsed_html.root[2][2][1][2]
        contest_results_elem = contest_outcomes[2][2][1]
        
        # direct array assignment
        contest_results[1] = string(text(contest_results_elem[1][2]))
        
        # Check if win method should be excluded
        if should_exclude_win_method(contest_results[1])
            println("Skipping fight with excluded win method: $(contest_results[1])")
            return nothing
        end
        
        round_end = parse(Int, string(text(contest_results_elem[2][2])))
        contest_results[2] = (round_end - 1) * 300 + convert_to_seconds(split(clean_result_data(contest_results_elem, 3), ':'))
        
        contest_results[3] = parse(Int, string(split(clean_result_data(contest_results_elem, 4), ' ')[1]))

        # Log fight details
        println("Method: $(contest_results[1]), Duration: $(contest_results[2]) seconds, Format: $(contest_results[3])")

        # scrape contest totals
        contest_totals_elem = contest_outcomes[4][1][2]
        
        # direct array assignment for fighter 1
        contest_totals_fighter1[1] = parse(Int, string(text(contest_totals_elem[1][2][1])))
        
        takedowns_fighter1 = split(string(text(contest_totals_elem[1][6][1])), ' ')
        contest_totals_fighter1[2] = parse(Int, takedowns_fighter1[3])
        contest_totals_fighter1[3] = parse(Int, takedowns_fighter1[1])
        
        contest_totals_fighter1[4] = parse(Int, string(text(contest_totals_elem[1][8][1])))
        contest_totals_fighter1[5] = parse(Int, string(text(contest_totals_elem[1][9][1])))
        contest_totals_fighter1[6] = convert_to_seconds(split(string(text(contest_totals_elem[1][10][1])), ':'))
        
        # direct array assignment for fighter 2
        contest_totals_fighter2[1] = parse(Int, string(text(contest_totals_elem[1][2][2])))
        
        takedowns_fighter2 = split(string(text(contest_totals_elem[1][6][2])), ' ')
        contest_totals_fighter2[2] = parse(Int, takedowns_fighter2[3])
        contest_totals_fighter2[3] = parse(Int, takedowns_fighter2[1])
        
        contest_totals_fighter2[4] = parse(Int, string(text(contest_totals_elem[1][8][2])))
        contest_totals_fighter2[5] = parse(Int, string(text(contest_totals_elem[1][9][2])))
        contest_totals_fighter2[6] = convert_to_seconds(split(string(text(contest_totals_elem[1][10][2])), ':'))

        # scrape significant strike totals
        sig_str_elem = contest_outcomes[7][2][1]
        
        # use indices to optimize array assignments
        # fighter 1 significant strikes
        head_fighter1 = split(string(text(sig_str_elem[4][1])), ' ')
        sig_str_totals_fighter1[1] = parse(Int, head_fighter1[1])
        sig_str_totals_fighter1[2] = parse(Int, head_fighter1[3])
        
        body_fighter1 = split(string(text(sig_str_elem[5][1])), ' ')
        sig_str_totals_fighter1[3] = parse(Int, body_fighter1[1])
        sig_str_totals_fighter1[4] = parse(Int, body_fighter1[3])
        
        leg_fighter1 = split(string(text(sig_str_elem[6][1])), ' ')
        sig_str_totals_fighter1[5] = parse(Int, leg_fighter1[1])
        sig_str_totals_fighter1[6] = parse(Int, leg_fighter1[3])
        
        dist_fighter1 = split(string(text(sig_str_elem[7][1])), ' ')
        sig_str_totals_fighter1[7] = parse(Int, dist_fighter1[1])
        sig_str_totals_fighter1[8] = parse(Int, dist_fighter1[3])
        
        clinch_fighter1 = split(string(text(sig_str_elem[8][1])), ' ')
        sig_str_totals_fighter1[9] = parse(Int, clinch_fighter1[1])
        sig_str_totals_fighter1[10] = parse(Int, clinch_fighter1[3])
        
        ground_fighter1 = split(string(text(sig_str_elem[9][1])), ' ')
        sig_str_totals_fighter1[11] = parse(Int, ground_fighter1[1])
        sig_str_totals_fighter1[12] = parse(Int, ground_fighter1[3])
        
        # fighter 2 significant strikes
        head_fighter2 = split(string(text(sig_str_elem[4][2])), ' ')
        sig_str_totals_fighter2[1] = parse(Int, head_fighter2[1])
        sig_str_totals_fighter2[2] = parse(Int, head_fighter2[3])
        
        body_fighter2 = split(string(text(sig_str_elem[5][2])), ' ')
        sig_str_totals_fighter2[3] = parse(Int, body_fighter2[1])
        sig_str_totals_fighter2[4] = parse(Int, body_fighter2[3])
        
        leg_fighter2 = split(string(text(sig_str_elem[6][2])), ' ')
        sig_str_totals_fighter2[5] = parse(Int, leg_fighter2[1])
        sig_str_totals_fighter2[6] = parse(Int, leg_fighter2[3])
        
        dist_fighter2 = split(string(text(sig_str_elem[7][2])), ' ')
        sig_str_totals_fighter2[7] = parse(Int, dist_fighter2[1])
        sig_str_totals_fighter2[8] = parse(Int, dist_fighter2[3])
        
        clinch_fighter2 = split(string(text(sig_str_elem[8][2])), ' ')
        sig_str_totals_fighter2[9] = parse(Int, clinch_fighter2[1])
        sig_str_totals_fighter2[10] = parse(Int, clinch_fighter2[3])
        
        ground_fighter2 = split(string(text(sig_str_elem[9][2])), ' ')
        sig_str_totals_fighter2[11] = parse(Int, ground_fighter2[1])
        sig_str_totals_fighter2[12] = parse(Int, ground_fighter2[3])

        # format data and return
        return reformat_contest_data(contest_fighter_bout_info, contest_results, 
            contest_totals_fighter1, contest_totals_fighter2, 
            sig_str_totals_fighter1, sig_str_totals_fighter2)

    catch e
        println("Error scraping contest $contest_url: $e")
        return nothing
    finally
        driver.quit()
    end
end

function extract_event_urls()
    driver = create_chrome_driver()
    event_urls = String[]
    
    try
        events_url = "http://ufcstats.com/statistics/events/completed?page=all"
        driver.get(events_url)

        wait_obj = wait.WebDriverWait(driver, 10)
        wait_obj.until(expected_conditions.presence_of_element_located((by.CLASS_NAME, "b-statistics__table-events")))
        
        # batch process links
        links = driver.find_elements(by.CLASS_NAME, "b-link_style_black")
        
        # pre-allocate the array with a reasonable size estimate
        sizehint!(event_urls, length(links))
        
        for link in links
            href = link.get_attribute("href")
            if href !== nothing && startswith(href, "http://ufcstats.com/event-details/")
                push!(event_urls, href)
            end
        end
        
        println("Found $(length(event_urls)) event URLs")
        
    catch e
        println("Error occurred while extracting event URLs: $e")
    finally
        driver.quit()
    end
    
    return event_urls
end

function extract_contest_urls(event_urls, start_year, end_year)
    driver = create_chrome_driver()
    contest_urls = String[]
    
    try
        total_events = length(event_urls)
        # pre-allocate with a reasonable estimate (avg 12 fights per event)
        sizehint!(contest_urls, total_events * 12)
        
        for (index, event_url) in enumerate(event_urls)
            println("Processing event $index of $total_events: $event_url")
            
            try
                driver.get(event_url)
                wait_obj = wait.WebDriverWait(driver, 10)
                
                # Get event date to check if it's within our year range
                wait_obj.until(expected_conditions.presence_of_element_located((by.CLASS_NAME, "b-list__box-list-item")))
                event_date_elem = driver.find_element(by.CLASS_NAME, "b-list__box-list-item")
                event_date_text = event_date_elem.text
                event_date = convert_date(split(replace(event_date_text, "," => ""), " "))
                year = get_year_from_date(event_date)
                
                if year < start_year || year > end_year
                    println("Skipping event from year $year (outside range $start_year-$end_year)")
                    continue
                end
                
                println("Event from year $year - processing")
                
                wait_obj.until(expected_conditions.presence_of_element_located((by.CLASS_NAME, "b-fight-details__table")))
                
                # extract all fight urls at once
                fight_rows = driver.find_elements(by.CSS_SELECTOR, "tr.b-fight-details__table-row.b-fight-details__table-row__hover.js-fight-details-click")
                
                # process in batch
                for row in fight_rows
                    contest_url = row.get_attribute("data-link")
                    if contest_url !== nothing
                        push!(contest_urls, contest_url)
                    end
                end
                
            catch e
                println("  Error processing event $event_url: $e")
                continue
            end
            
            # throttle to avoid overloading the server
            sleep(0.2)
        end
        
    catch e
        println("Error occurred while extracting contest URLs: $e")
    finally
        driver.quit()
    end
    
    println("Total fight contest URLs collected: $(length(contest_urls))")
    return contest_urls
end

function scrape_ufc(contest_urls, start_year, end_year, output_file, benchmark_interval)
    # pre-allocate with reasonable size (2 fighters per contest)
    match_summaries = Vector{Any}(undef, 0)
    sizehint!(match_summaries, length(contest_urls) * 2)
    
    # csv header
    header = ["date", "weight_class", "name", "match_result", "end_method", "match_duration", 
             "time_format", "knockdowns", "takedown_attempts", "takedowns_landed", 
             "submission_attempts", "reversals", "control_time", "head_landed", 
             "head_attempted", "body_landed", "body_attempted", "leg_landed", 
             "leg_attempted", "distance_landed", "distance_attempted", "clinch_landed", 
             "clinch_attempted", "ground_landed", "ground_attempted"]
    
    # process contest_urls
    total_contests = length(contest_urls)
    println("Starting to process $total_contests fight summaries...")
    
    processed_count = 0
    benchmark_count = 0
    
    # process contests
    for (index, contest_url) in enumerate(contest_urls)
        try
            println("Processing fight $(index) of $(total_contests): $(contest_url)")
            
            result = scrape_contest(contest_url, start_year, end_year)
            
            if result !== nothing
                fighter1_data, fighter2_data = result
                push!(match_summaries, fighter1_data)
                push!(match_summaries, fighter2_data)
                processed_count += 1
                
                # Save benchmark file every N contests
                if index > 0 && index % benchmark_interval == 0
                    benchmark_count += 1
                    save_benchmark(match_summaries, header, output_file, benchmark_count)
                end
            end
            
            # throttle to avoid overloading the server
            sleep(0.2)
            
        catch e
            println("Error processing fight $contest_url: $e")
            println(stacktrace())
            
            # Save emergency benchmark if we've processed enough fights
            if index > 0 && index % 50 == 0 && length(match_summaries) > 0
                try
                    save_benchmark(match_summaries, header, output_file, "emergency_$(index)")
                catch bench_err
                    println("Failed to save emergency benchmark: $bench_err")
                end
            end
        end
    end
    
    # Save final complete benchmark
    if length(match_summaries) > 0
        save_benchmark(match_summaries, header, output_file, "complete")
    end
    
    # save dataset to main output file
    save_to_csv(match_summaries, header, output_file)
    println("Dataset saved to $output_file")
    println("Processed $processed_count fights out of $total_contests URLs")
    println("Total fighter records: $(length(match_summaries))")
    
    return match_summaries
end

function parse_commandline()
    s = ArgParseSettings()
    
    @add_arg_table! s begin
        "--start-year", "-s"
            help = "Start year (default: 2001)"
            arg_type = Int
            default = 2001
        "--end-year", "-e"
            help = "End year (default: 2018)"
            arg_type = Int
            default = 2018
        "--output-file", "-o"
            help = "Output CSV file (default: ufc_match_summaries.csv)"
            arg_type = String
            default = "ufc_match_summaries.csv"
        "--benchmark-interval", "-i"
            help = "Save benchmark files every N contests (default: 100)"
            arg_type = Int
            default = 100
        "--throttle", "-t"
            help = "Milliseconds to wait between requests (default: 200)"
            arg_type = Int
            default = 200
    end
    
    return parse_args(s)
end

function main()
    # parse command line arguments
    parsed_args = parse_commandline()
    start_year = parsed_args["start-year"]
    end_year = parsed_args["end-year"]
    output_file = parsed_args["output-file"] 
    benchmark_interval = parsed_args["benchmark-interval"]
    throttle = parsed_args["throttle"] / 1000  # convert to seconds
    
    println("UFC Scraper - filtering fights from $start_year to $end_year")
    println("Output file: $output_file")
    println("Benchmark interval: every $benchmark_interval contests")
    println("Throttle: $(throttle*1000) ms")
    
    # Create log file
    log_file = "$(splitext(output_file)[1])_scraper.log"
    log_io = open(log_file, "w")
    
    # Save original stdout and redirect to both console and log file
    original_stdout = stdout
    redirect_stdout(TeeStream(original_stdout, log_io))
    
    # initialize the pycall modules
    __init__()
    
    try
        start_time = time()
        
        # extract events
        println("Extracting event URLs...")
        event_urls = extract_event_urls()
        println("Extracted $(length(event_urls)) event URLs")
        
        # Save event URLs to file for recovery if needed
        event_urls_file = "$(splitext(output_file)[1])_event_urls.json"
        open(event_urls_file, "w") do io
            println(io, "[")
            for (i, url) in enumerate(event_urls)
                println(io, "  \"$url\"$(i < length(event_urls) ? "," : "")")
            end
            println(io, "]")
        end
        println("Saved event URLs to $event_urls_file")
        
        # extract contests
        println("Extracting contest URLs...")
        contest_urls = extract_contest_urls(event_urls, start_year, end_year)
        println("Extracted $(length(contest_urls)) contest URLs")
        
        # Save contest URLs to file for recovery if needed
        contest_urls_file = "$(splitext(output_file)[1])_contest_urls.json"
        open(contest_urls_file, "w") do io
            println(io, "[")
            for (i, url) in enumerate(contest_urls)
                println(io, "  \"$url\"$(i < length(contest_urls) ? "," : "")")
            end
            println(io, "]")
        end
        println("Saved contest URLs to $contest_urls_file")
        
        # scrape UFC data
        println("Scraping UFC fight data...")
        scrape_ufc(contest_urls, start_year, end_year, output_file, benchmark_interval)
        
        end_time = time()
        println("Total execution time: $(round(end_time - start_time, digits=2)) seconds")
        
    catch e
        println("Fatal error in main function: $e")
        println(stacktrace())
    finally
        # Restore original stdout
        redirect_stdout(original_stdout)
        close(log_io)
    end
end

# TeeStream to redirect output to both console and log file
struct TeeStream <: IO
    out1::IO
    out2::IO
end

function Base.write(ts::TeeStream, x::UInt8)
    write(ts.out1, x)
    write(ts.out2, x)
    return 1
end

function Base.write(ts::TeeStream, x::AbstractVector{UInt8})
    n = length(x)
    write(ts.out1, x)
    write(ts.out2, x)
    return n
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end