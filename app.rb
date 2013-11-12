require 'bundler/setup'
require 'sinatra/base'
require 'sinatra/flash'
require 'sinatra/reloader'
require 'health_graph'
require 'nike'
require 'geoutm'

APP_DOMAIN = ENV['APP_DOMAIN'] || 'http://localhost:9292'
APP_SECRET = ENV['APP_SECRET'] || 'nikeplus-to-runkeeper'
RUNKEEPER_CLIENT_ID = ENV['RUNKEEPER_CLIENT_ID']
RUNKEEPER_CLIENT_SECRET = ENV['RUNKEEPER_CLIENT_SECRET']

HealthGraph.configure do |config|
  config.client_id = RUNKEEPER_CLIENT_ID
  config.client_secret = RUNKEEPER_CLIENT_SECRET
  config.authorization_redirect_url = "#{APP_DOMAIN}/auth/runkeeper/callback"
end

RunkeeperUser = Struct.new(:id, :token, :username, :fullname) do
  def display_name
    fullname || username
  end
end

class NikePlusToRunkeeperImporter < Sinatra::Base
  use Rack::Session::Cookie, key: 'nikeplus-to-runkeeper', secret: APP_SECRET
  register Sinatra::Flash

  configure :development do
    register Sinatra::Reloader
  end

  helpers do
    def user
      if !@user && signed_in?
        hash = session[:user]
        @user = RunkeeperUser.new(hash[:id], hash[:token], hash[:username], hash[:fullname])
      end
      @user
    end

    def signed_in?
      session.has_key?(:user)
    end
  end

  get '/' do
    if signed_in?
      redirect to('/import')
    else
      %(<a href="#{url('/auth/runkeeper')}">Login</a>)
    end
  end

  get '/import' do
    return redirect to('/') unless signed_in?

    day  = 60 * 60 * 24
    periods = [
      { name: 'Last week', value: Time.now - (day * 7) },
      { name: 'Last 30 days', value: Time.now - (day * 30) },
      { name: 'Last year', value: Time.now - (day * 365) },
      { name: 'Everything', value: '' }
    ]
    erb(:import, locals: { periods: periods })
  end

  post '/import' do
    return redirect to('/') unless signed_in?

    nike_client = Nike::Client.new(params[:email], params[:password])
    nike_activities = nike_client.activities
    activity_cutoff = Time.parse(params[:activity_since]) unless params[:activity_since].to_s.empty?

    runkeeper_activities = nike_activities.map do |a|
      next if activity_cutoff && a.start_time_utc < activity_cutoff

      nike_activity = nike_client.activity(a.activity_id)
      duration = nike_activity.duration / 1000

      runkeeper_activity = {
        type: 'Running',
        start_time: nike_activity.start_time_utc,
        total_distance: nike_activity.distance * 1000,
        duration: duration,
        detect_pauses: true,
        total_calories: nike_activity.calories.to_f,
        average_heart_rate: nike_activity.average_heart_rate.to_f
      }

      if a.gps && nike_activity.geo
        index = -1
        total = nike_activity.geo.waypoints.size
        fraction = duration.to_f / total.to_f
        last_path = nil
        last_delta = nil

        paths = []
        nike_activity.geo.waypoints.each_with_index do |wp, index|
          type = 'gps'
          type = 'start' if index == 0
          type = 'end'   if (index + 1) == total

          path = {
            timestamp: fraction * (index += 1),
            altitude: wp['ele'],
            longitude: wp['lon'],
            latitude: wp['lat'],
            type: type
          }

          # Account for pauses in the run by calculating the distance between
          # waypoints, when we detect a large enough jump we assume the run
          # was paused and add a "pause" waypoing into the path.
          if last_path
            next_utm = GeoUtm::LatLon.new(path[:latitude], path[:longitude]).to_utm
            last_utm = GeoUtm::LatLon.new(last_path[:latitude], last_path[:longitude]).to_utm
            delta = last_utm.distance_to(next_utm)

            if last_delta && delta > 0 && delta > (last_delta * 2)
              # For some reason the API does not like a "resume" node to be
              # added afterwards but will detect the next point just fine.
              paused_path = last_path.clone
              paused_path[:type] = 'pause'

              paths << paused_path.clone
            end

            last_delta = delta if delta > 0
          end

          paths << last_path = path
        end

        runkeeper_activity[:path] = paths
      end

      runkeeper_activity
    end.compact

    erb(:export, locals: { activities: runkeeper_activities })
  end

  post '/export' do
    return redirect to('/') unless signed_in?

    activities = params[:activities]
    activities.each do |activity|
      parsed = JSON.parse(activity, symbolize_names: true)
      parsed[:start_time] = Time.parse(parsed[:start_time]).httpdate

      HealthGraph::NewFitnessActivity.new(user.token, parsed)
    end

    flash[:info] = "Successfully imported #{activities.size} activities"

    redirect to('/import')
  end

  get '/auth/runkeeper' do
    redirect to(HealthGraph.authorize_url)
  end

  get '/auth/runkeeper/callback' do
    raise 'Authentication Error' unless params[:code]

    access_token = HealthGraph.access_token(params[:code])
    user = HealthGraph::User.new(access_token)
    profile = user.profile

    session[:user] = {
      id: user.userID,
      username: profile.profile.split('/').last,
      fullname: profile.name,
      token: access_token
    }

    redirect to('/import')
  end
end
