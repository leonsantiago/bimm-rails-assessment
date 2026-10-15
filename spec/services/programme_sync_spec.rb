require "rails_helper"

RSpec.describe ProgrammeSync do
  def sync(generation: 1, **params)
    described_class.new(client: api_client, generation: generation, **params).call
  end

  it "imports all pages, including their nested films and venues" do
    sync

    expect(Screening.count).to eq(60)
    expect(Film.count).to eq(12)
    expect(Venue.count).to eq(6)
    expect(Screening.find_by!(external_id: "SCR-0060")).to have_attributes(
      film: Film.find_by!(external_id: "FILM-012"),
      venue: Venue.find_by!(external_id: "VEN-06"),
      starts_at: Time.utc(2027, 3, 5, 14), status: "scheduled"
    )
    expect(Film.find_by!(external_id: "FILM-001")).to have_attributes(
      title: "The Silent Orchard", synopsis: "A beekeeper's last summer in the hills.", runtime: 118, year: 2024
    )
    expect(Venue.find_by!(external_id: "VEN-01")).to have_attributes(
      name: "Grand Cinema", address: "12 Main Street", capacity: 320
    )
  end

  it "preserves identities and timestamps when repeated without changes" do
    sync
    before = [ Film, Venue, Screening ].map { |model| model.order(:id).pluck(:id, :external_id, :updated_at) }

    sync

    expect([ Film, Venue, Screening ].map { |model| model.order(:id).pluck(:id, :external_id, :updated_at) }).to eq(before)
  end

  it "propagates generation two changes without replacing existing records" do
    sync
    film_id = Film.find_by!(external_id: "FILM-005").id
    venue_id = Venue.find_by!(external_id: "VEN-03").id

    sync(generation: 2)

    expect(Film.find(film_id).title).to eq("Autumn in Trieste (Director's Cut)")
    expect(Venue.find(venue_id).name).to eq("City Gallery Auditorium")
    MockApi::Dataset::MOVED_VENUES_G2.each do |screening_id, external_venue_id|
      expect(Screening.find_by!(external_id: screening_id).venue.external_id).to eq(external_venue_id)
    end
    expect(Screening.where(status: "cancelled").pluck(:external_id)).to match_array(%w[SCR-0010 SCR-0011 SCR-0012])
    expect(Screening.count).to eq(62)
    expect(Screening.where(external_id: %w[SCR-0061 SCR-0062]).count).to eq(2)
    expect(Screening.exists?(external_id: "SCR-0060")).to be(true)
    expect(Film.count).to eq(12)
    expect(Venue.count).to eq(6)
  end

  it "commits eight records before a later page fails and can safely retry" do
    expect { sync(fail_after: 8) }.to raise_error(FestivalApiClient::Error, /HTTP 500/)

    expect(Screening.order(:external_id).pluck(:external_id)).to eq((1..8).map { |n| format("SCR-%04d", n) })
    expect(Film.count).to eq(8)
    expect(Venue.count).to eq(6)

    sync
    expect(Screening.count).to eq(60)
  end

  it "uses external IDs even when titles and venue names are identical" do
    create(:film, external_id: "OTHER-FILM", title: "The Silent Orchard")
    create(:venue, external_id: "OTHER-VENUE", name: "Grand Cinema")

    sync

    expect(Film.count).to eq(13)
    expect(Venue.count).to eq(7)
    expect(Screening.find_by!(external_id: "SCR-0001").film.external_id).to eq("FILM-001")
    expect(Screening.find_by!(external_id: "SCR-0001").venue.external_id).to eq("VEN-01")
  end

  it "updates all upstream attributes and can reassign a screening's film" do
    sync
    record = MockApi::Dataset.generation_one.first
    record["film"] = MockApi::Dataset.generation_one.second["film"].merge(
      "synopsis" => "New synopsis", "runtime" => 120, "year" => 2025
    )
    record["venue"].merge!("address" => "New address", "capacity" => 400)
    record["starts_at"] = "2027-03-22T21:00:00Z"
    client = api_client { [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 1, screenings: [ record ] }.to_json ] }

    described_class.new(client: client).call

    screening = Screening.find_by!(external_id: "SCR-0001")
    expect(screening.starts_at).to eq(Time.utc(2027, 3, 22, 21))
    expect(screening.film).to have_attributes(external_id: "FILM-002", synopsis: "New synopsis", runtime: 120, year: 2025)
    expect(screening.venue).to have_attributes(address: "New address", capacity: 400)
  end

  it "does not write records when the API page is malformed" do
    client = api_client { [ 200, {}, { screenings: [] }.to_json ] }

    expect { described_class.new(client: client).call }.to raise_error(FestivalApiClient::Error)
    expect([ Film.count, Venue.count, Screening.count ]).to eq([ 0, 0, 0 ])
  end

  it "rejects malformed nested records while preserving previous imports" do
    records = MockApi::Dataset.generation_one.first(2)
    records.last["venue"] = nil
    client = api_client { [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 2, screenings: records }.to_json ] }

    expect { described_class.new(client: client).call }.to raise_error(described_class::InvalidRecord)
    expect(Screening.pluck(:external_id)).to eq([ "SCR-0001" ])
    expect(Film.count).to eq(1)
    expect(Venue.count).to eq(1)
  end

  it "rolls back related updates when a screening cannot be saved" do
    sync
    record = MockApi::Dataset.generation_one.first
    record["film"]["title"] = "Changed title"
    record["venue"]["name"] = "Changed venue"
    record["starts_at"] = "invalid timestamp"
    client = api_client { [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 1, screenings: [ record ] }.to_json ] }

    expect { described_class.new(client: client).call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(Film.find_by!(external_id: "FILM-001").title).to eq("The Silent Orchard")
    expect(Venue.find_by!(external_id: "VEN-01").name).to eq("Grand Cinema")
    expect(Screening.count).to eq(60)
  end

  it "rolls back new film and venue rows when a screening cannot be saved" do
    record = MockApi::Dataset.generation_one.first
    record["starts_at"] = "invalid timestamp"
    client = api_client { [ 200, {}, { page: 1, per_page: 25, total_pages: 1, total_count: 1, screenings: [ record ] }.to_json ] }

    expect { described_class.new(client: client).call }.to raise_error(ActiveRecord::RecordInvalid)
    expect([ Film.count, Venue.count, Screening.count ]).to eq([ 0, 0, 0 ])
  end
end
