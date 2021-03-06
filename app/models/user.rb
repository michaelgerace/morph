# A real human being (hopefully)
class User < Owner
  include Skylight::Helpers

  devise :trackable, :rememberable, :omniauthable, omniauth_providers: [:github]
  has_and_belongs_to_many :organizations, join_table: :organizations_users
  has_many :alerts
  has_many :contributions
  has_many :scrapers_contributed_to, through: :contributions, source: :scraper

  def see_downloads
    get_feature_switch_value(:see_downloads, false)
  end

  def see_downloads=(value)
    set_feature_switch_value(:see_downloads, value)
  end

  # In most cases people have contributed to the scrapers that they own so we
  # really don't want to see these twice. This method just removes their own
  # scrapers from the list
  def other_scrapers_contributed_to
    scrapers_contributed_to - scrapers
  end

  # A list of all owners thst this user can write to. Includes itself
  def all_owners
    [self] + organizations
  end

  def reset_authorization!
    update_attributes(
      access_token: Morph::Github.reset_authorization(access_token))
  end

  # Send all alerts. This method should be run from a daily cron job
  def self.process_alerts
    User.all.each(&:process_alerts)
  end

  def process_alerts
    return if watched_broken_scrapers_ordered_by_urgency.empty?
    AlertMailer.alert_email(
      self,
      watched_broken_scrapers_ordered_by_urgency,
      watched_successful_scrapers).deliver
  rescue Net::SMTPSyntaxError
    puts "Warning: user #{nickname} has invalid email address #{email} " \
      '(tried to send alert)'
  end

  def user?
    true
  end

  def organization?
    false
  end

  def toggle_watch(object)
    if watching?(object)
      alerts.where(watch: object).first.destroy
    else
      # If we're starting to watch a whole bunch of scrapers (by watching a
      # user/org) and we're already following one of those scrapers individually
      # then remove the individual alert
      alerts.create(watch: object)
      if object.respond_to?(:scrapers)
        alerts.where(watch_id: object.scrapers,
                     watch_type: 'Scraper').destroy_all
      end
    end
  end

  # Only include scrapers that finished in the last 24 hours
  def watched_successful_scrapers
    all_scrapers_watched.select do |s|
      s.finished_successfully? && s.finished_recently?
    end
  end

  instrument_method
  def watched_broken_scrapers
    all_scrapers_watched.select do |s|
      s.finished_with_errors? && s.finished_recently?
    end
  end

  instrument_method
  # Puts scrapers that have most recently failed first
  def watched_broken_scrapers_ordered_by_urgency
    watched_broken_scrapers.sort do |a,b|
      if b.latest_successful_run_time.nil? && a.latest_successful_run_time.nil?
        0
      elsif b.latest_successful_run_time.nil?
        -1
      elsif a.latest_successful_run_time.nil?
        1
      else
        b.latest_successful_run_time <=> a.latest_successful_run_time
      end
    end
  end

  def organizations_watched
    alerts.map(&:watch).select { |w| w.is_a?(Organization) }
  end

  def users_watched
    alerts.map(&:watch).select { |w| w.is_a?(User) }
  end

  def scrapers_watched
    alerts.map(&:watch).select { |w| w.is_a?(Scraper) }
  end

  def all_scrapers_watched
    s = scrapers_watched
    (organizations_watched + users_watched).each { |owner| s += owner.scrapers }
    s.uniq
  end

  # Are we watching this scraper because we're watching the owner
  # of the scraper?
  def indirectly_watching?(scraper)
    watching?(scraper.owner)
  end

  def watching?(object)
    alerts.map(&:watch).include? object
  end

  def refresh_organizations!
    self.organizations = octokit_client.organizations.map do |data|
      Organization.find_or_create(data.id, data.login, octokit_client)
    end
  end

  def octokit_client
    Octokit::Client.new access_token: access_token
  end

  def self.find_for_github_oauth(auth, _signed_in_resource = nil)
    user = User.find_or_create_by(provider: auth.provider, uid: auth.uid)
    user.update_attributes(nickname: auth.info.nickname,
                           access_token: auth.credentials.token)
    user.refresh_info_from_github!
    # Also every time you login it should update the list of organizations that
    # the user is attached to
    user.refresh_organizations!
    user
  end

  def refresh_info_from_github!
    user = octokit_client.user(nickname)
    update_attributes(name: user.name,
                      gravatar_url: user._rels[:avatar].href,
                      blog: user.blog,
                      company: user.company,
                      email: Morph::Github.primary_email(self))
  end

  def self.find_or_create_by_nickname(nickname)
    u = User.find_by_nickname(nickname)
    if u.nil?
      u = User.create(nickname: nickname)
      u.refresh_info_from_github!
    end
    u
  end

  def users
    []
  end

  def active_for_authentication?
    !suspended?
  end

  def inactive_message
    'Your account has been suspended. ' \
      'Please contact us if you think this is in error.'
  end
end
