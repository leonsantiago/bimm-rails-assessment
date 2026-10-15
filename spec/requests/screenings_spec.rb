require "rails_helper"

RSpec.describe "Screenings", type: :request do
  let!(:main_venue) { create(:venue, name: "Grand Cinema") }
  let!(:other_venue) { create(:venue, name: "Riverside Cinema") }

  before do
    create(:screening, film: create(:film, title: "Autumn in Trieste"), venue: main_venue, starts_at: Time.utc(2027, 3, 12, 10))
    create(:screening, film: create(:film, title: "Northern Lights"), venue: other_venue, starts_at: Time.utc(2027, 3, 12, 20))
    create(:screening, film: create(:film, title: "Quiet Tide"), venue: main_venue, starts_at: Time.utc(2027, 3, 13, 10))
    create(:screening, film: create(:film, title: "Autumn Echo"), venue: other_venue, starts_at: Time.utc(2027, 3, 13, 20))
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def titles
    document.css("turbo-frame#screenings tbody tr td:first-child").map(&:text)
  end

  it "lists screenings in start time order" do
    get screenings_path

    expect(response).to have_http_status(:ok)
    expect(titles).to eq([ "Autumn in Trieste", "Northern Lights", "Quiet Tide", "Autumn Echo" ])
  end

  it "displays start times in the application timezone" do
    Time.use_zone("America/New_York") do
      get screenings_path, params: { date: "2027-03-12", q: "Autumn in Trieste" }

      expect(response).to have_http_status(:ok)
      expect(document.at_css("turbo-frame#screenings tbody tr td:nth-child(3)").text).to eq("Fri 12 Mar, 5:00am")
    end
  end

  it "filters by date" do
    get screenings_path, params: { date: "2027-03-12" }

    expect(titles).to eq([ "Autumn in Trieste", "Northern Lights" ])
  end

  it "uses the configured timezone and includes the entire local day" do
    Time.use_zone("America/New_York") do
      date = Date.new(2027, 3, 14)
      start = Time.zone.local(date.year, date.month, date.day)
      finish = start.end_of_day
      create(:screening, film: create(:film, title: "Before day"), starts_at: start - 1.second)
      create(:screening, film: create(:film, title: "Start boundary"), starts_at: start)
      create(:screening, film: create(:film, title: "End boundary"), starts_at: finish)
      create(:screening, film: create(:film, title: "After day"), starts_at: start.next_day)

      get screenings_path, params: { date: date.iso8601 }

      expect(titles).to eq([ "Start boundary", "End boundary" ])
    end
  end

  it "ignores an invalid date without raising" do
    get screenings_path, params: { date: "not-a-date" }

    expect(response).to have_http_status(:ok)
    expect(titles.size).to eq(4)
  end

  it "filters by local venue ID" do
    get screenings_path, params: { venue_id: main_venue.id }

    expect(titles).to eq([ "Autumn in Trieste", "Quiet Tide" ])
  end

  it "matches partial titles case insensitively" do
    get screenings_path, params: { q: "aUtUmN" }

    expect(titles).to eq([ "Autumn in Trieste", "Autumn Echo" ])
  end

  it "treats SQL wildcard characters as literal search text" do
    create(:screening, film: create(:film, title: "100%_Complete"))

    get screenings_path, params: { q: "%_" }

    expect(titles).to eq([ "100%_Complete" ])
  end

  it "treats SQL syntax as literal search text" do
    get screenings_path, params: { q: "' OR 1=1 --" }

    expect(response).to have_http_status(:ok)
    expect(titles).to eq([ "No screenings match your filters." ])
  end

  it "combines filters and preserves form values" do
    get screenings_path, params: { date: "2027-03-12", venue_id: main_venue.id, q: "autumn" }

    expect(titles).to eq([ "Autumn in Trieste" ])
    expect(document.at_css('input[name="date"]')["value"]).to eq("2027-03-12")
    expect(document.at_css('select[name="venue_id"] option[selected]')["value"]).to eq(main_venue.id.to_s)
    expect(document.at_css('input[name="q"]')["value"]).to eq("autumn")
  end

  it "displays an empty result message" do
    get screenings_path, params: { q: "unmatched title" }

    expect(titles).to eq([ "No screenings match your filters." ])
  end

  it "targets the results frame and returns the matching frame for Turbo requests" do
    get screenings_path, params: { venue_id: other_venue.id }, headers: { "Turbo-Frame" => "screenings" }

    expect(response).to have_http_status(:ok)
    expect(document.css("turbo-frame#screenings").size).to eq(1)
    expect(document.at_css("form")["data-turbo-frame"]).to eq("screenings")
    expect(document.at_css("form")["method"]).to eq("get")
    expect(titles).to eq([ "Northern Lights", "Autumn Echo" ])
  end

  it "breaks start-time ties consistently using the screening ID" do
    create(:screening, film: create(:film, title: "Tie first"), starts_at: Time.utc(2027, 3, 15, 10))
    create(:screening, film: create(:film, title: "Tie second"), starts_at: Time.utc(2027, 3, 15, 10))

    get screenings_path, params: { date: "2027-03-15" }

    expect(titles).to eq([ "Tie first", "Tie second" ])
  end

  def listing_query_count(params = {})
    queries = []
    subscriber = ->(*args) do
      payload = args.last
      queries << payload[:sql] if !payload[:cached] && payload[:sql].match?(/\bFROM\s+"(?:screenings|films|venues)"/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      ActiveRecord::Base.uncached { get screenings_path, params: params }
    end
    expect(response).to have_http_status(:ok)
    queries.size
  end

  it "keeps query counts constant as more films and venues are displayed" do
    get screenings_path
    small_count = listing_query_count
    small_search_count = listing_query_count(q: "i")

    8.times do |n|
      create(:screening, film: create(:film, title: "Extra film #{n}"), venue: create(:venue))
    end

    expect(listing_query_count).to eq(small_count)
    expect(titles.size).to eq(12)
    expect(listing_query_count(q: "i")).to eq(small_search_count)
    expect(titles.size).to eq(11)
  end
end
