class ScreeningsController < ApplicationController
  def index
    @venues = Venue.order(:name)

    @screenings = Screening.includes(:film, :venue).order(:starts_at, :id)
    @screenings = @screenings.where(venue_id: params[:venue_id]) if params[:venue_id].present?

    if params[:date].present?
      date = begin
        Date.iso8601(params[:date])
      rescue ArgumentError
        nil
      end
      @screenings = @screenings.where(starts_at: Time.zone.local(date.year, date.month, date.day).all_day) if date
    end

    if params[:q].present?
      query = ActiveRecord::Base.sanitize_sql_like(params[:q].strip)
      @screenings = @screenings.joins(:film).where("films.title ILIKE ?", "%#{query}%")
    end
  end
end
