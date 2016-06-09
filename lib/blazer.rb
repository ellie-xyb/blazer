require "csv"
require "yaml"
require "chartkick"
require "blazer/version"
require "blazer/data_source"
require "blazer/engine"

module Blazer
  class Error < StandardError; end
  class TimeoutNotSupported < Error; end

  class << self
    attr_accessor :audit
    attr_reader :time_zone
    attr_accessor :user_name
    attr_accessor :user_class
    attr_accessor :user_method
    attr_accessor :before_action
    attr_accessor :from_email
    attr_accessor :cache
    attr_accessor :transform_statement
    attr_accessor :check_schedules
    attr_accessor :async
  end
  self.audit = true
  self.user_name = :name
  self.check_schedules = ["5 minutes", "1 hour", "1 day"]
  self.async = false

  TIMEOUT_MESSAGE = "Query timed out :("
  TIMEOUT_ERRORS = [
    "canceling statement due to statement timeout", # postgres
    "cancelled on user's request", # redshift
    "canceled on user's request", # redshift
    "system requested abort", # redshift
    "maximum statement execution time exceeded" # mysql
  ]
  BELONGS_TO_OPTIONAL = {}
  BELONGS_TO_OPTIONAL[:optional] = true if Rails::VERSION::MAJOR >= 5

  def self.time_zone=(time_zone)
    @time_zone = time_zone.is_a?(ActiveSupport::TimeZone) ? time_zone : ActiveSupport::TimeZone[time_zone.to_s]
  end

  def self.settings
    @settings ||= begin
      path = Rails.root.join("config", "blazer.yml").to_s
      if File.exist?(path)
        YAML.load(ERB.new(File.read(path)).result)
      else
        {}
      end
    end
  end

  def self.data_sources
    @data_sources ||= begin
      ds = Hash[
        settings["data_sources"].map do |id, s|
          [id, Blazer::DataSource.new(id, s)]
        end
      ]
      ds.default = ds.values.first
      ds
    end
  end

  def self.run_checks(schedule: nil)
    checks = Blazer::Check.includes(:query)
    checks = checks.where(schedule: schedule) if schedule
    checks.find_each do |check|
      rows = nil
      error = nil
      tries = 1

      ActiveSupport::Notifications.instrument("run_check.blazer", check_id: check.id, query_id: check.query.id, state_was: check.state) do |instrument|
        # try 3 times on timeout errors
        while tries <= 3
          data_source = data_sources[check.query.data_source]
          statement = check.query.statement
          Blazer.transform_statement.call(data_source, statement) if Blazer.transform_statement
          columns, rows, error, cached_at = data_source.run_statement(statement, refresh_cache: true)
          if error == Blazer::TIMEOUT_MESSAGE
            Rails.logger.info "[blazer timeout] query=#{check.query.name}"
            tries += 1
            sleep(10)
          elsif error.to_s.start_with?("PG::ConnectionBad")
            data_sources[check.query.data_source].reconnect
            Rails.logger.info "[blazer reconnect] query=#{check.query.name}"
            tries += 1
            sleep(10)
          else
            break
          end
        end
        check.update_state(rows, error)
        # TODO use proper logfmt
        Rails.logger.info "[blazer check] query=#{check.query.name} state=#{check.state} rows=#{rows.try(:size)} error=#{error}"

        instrument[:state] = check.state
        instrument[:rows] = rows.try(:size)
        instrument[:error] = error
        instrument[:tries] = tries
      end

    end
  end

  def self.send_failing_checks
    emails = {}
    Blazer::Check.includes(:query).where(state: ["failing", "error", "timed out", "disabled"]).find_each do |check|
      check.split_emails.each do |email|
        (emails[email] ||= []) << check
      end
    end

    emails.each do |email, checks|
      Blazer::CheckMailer.failing_checks(email, checks).deliver_later
    end
  end
end
