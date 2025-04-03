using PyCall
using Gumbo

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

# optimized helper functions with type annotations
function convert_date(date_ls::Vector{SubString{String}})::Int
    return parse(Int, join([date_ls[4], date_ls[3], MONTH_MAP[date_ls[2]]], ""))
end

function convert_to_seconds(match_duration::Vector{SubString{String}})::Int
    return parse(Int, match_duration[1]) * 60 + parse(Int, match_duration[2])
end

function clean_result_data(contest_results_elem, elem)::String
    return strip(string(text(contest_results_elem[elem][2])), [' ', '\n'])
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

function scrape_contest(contest_url)
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
        event_link = driver.find_element(by.CLASS_NAME, "b-link")
        event_link.click()
        wait_obj.until(expected_conditions.presence_of_element_located((by.CLASS_NAME, "b-list__box-list-item")))
        event_date = convert_date(split(replace(driver.find_element(by.CLASS_NAME, "b-list__box-list-item").text, "," => ""), " "))
        driver.back()
        wait_obj.until(expected_conditions.presence_of_element_located((by.CLASS_NAME, "b-fight-details")))
        
        # store values directly in pre-allocated array
        contest_fighter_bout_info[1] = event_date
        
        bout_info = parsed_html.root[2][2][1][2][2][1][1]
        contest_fighter_bout_info[2] = strip(replace(string(text(bout_info)), "UFC" => "", "Title" => "", "Bout" => ""))
        contest_fighter_bout_info[3] = string(text(contest_fighter_info[1][1]))
        contest_fighter_bout_info[4] = string(text(contest_fighter_info[1][2][1][1]))
        contest_fighter_bout_info[5] = string(text(contest_fighter_info[2][1]))
        contest_fighter_bout_info[6] = string(text(contest_fighter_info[2][2][1][1]))

        # scrape contest results
        contest_outcomes = parsed_html.root[2][2][1][2]
        contest_results_elem = contest_outcomes[2][2][1]
        
        # direct array assignment
        contest_results[1] = string(text(contest_results_elem[1][2]))
        
        round_end = parse(Int, string(text(contest_results_elem[2][2])))
        contest_results[2] = (round_end - 1) * 300 + convert_to_seconds(split(clean_result_data(contest_results_elem, 3), ':'))
        
        contest_results[3] = parse(Int, string(split(clean_result_data(contest_results_elem, 4), ' ')[1]))

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
        
    catch e
        println("Error occurred: $e")
    finally
        driver.quit()
    end
    
    return event_urls
end

function extract_contest_urls(event_urls)
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
            
            # reduced sleep time slightly
            sleep(0.2)
        end
        
    catch e
        println("Error occurred: $e")
    finally
        driver.quit()
    end
    
    println("Total fight contest URLs collected: $(length(contest_urls))")
    return contest_urls
end

function scrape_ufc(contest_urls)
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
    total_summaries = length(contest_urls)
    println("Starting to process $total_summaries fight summaries...")
    
    # enable parallelization for independent tasks
    # note: we keep a single thread for web scraping to avoid overloading the server
    for (index, contest_url) in enumerate(contest_urls)
        try
            println("Processing fight $index of $total_summaries: $contest_url")
            
            fighter1_data, fighter2_data = scrape_contest(contest_url)
            push!(match_summaries, fighter1_data)
            push!(match_summaries, fighter2_data)
            
            # reduced sleep time slightly
            sleep(0.2)
            
        catch e
            println("Error processing fight $contest_url: $e")
            println(stacktrace())
        end
    end
    
    # save dataset
    save_to_csv(match_summaries, header, "ufc_match_summaries.csv")
    println("Dataset saved to ufc_match_summaries.csv")
    return match_summaries
end

function main()
    # initialize the pycall modules
    __init__()
    
    # extract events
    event_urls = extract_event_urls()

    # extract contests
    contest_urls = extract_contest_urls(event_urls)

    # save contest summaries
    scrape_ufc(contest_urls)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end