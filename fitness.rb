require 'rubygems'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/file_storage'
require 'sinatra'
require 'logger'

enable :sessions

CREDENTIAL_STORE_FILE = "#{$0}-oauth2.json"

def logger; settings.logger end

def api_client; settings.api_client; end

def fitness_api; settings.fitness; end

def user_credentials
  # Build a per-request oauth credential based on token stored in session
  # which allows us to use a shared API client.
  @authorization ||= (
    auth = api_client.authorization.dup
    auth.redirect_uri = to('/oauth2callback')
    auth.update_token!(session)
    auth
  )
end

configure do
  log_file = File.open('fitness.log', 'a+')
  log_file.sync = true
  logger = Logger.new(log_file)
  logger.level = Logger::DEBUG

  Google::APIClient.logger.level = Logger::DEBUG

  client = Google::APIClient.new(
    :application_name => 'Ruby Calendar sample',
    :application_version => '1.0.0'
  )

  file_storage = Google::APIClient::FileStorage.new(CREDENTIAL_STORE_FILE)
  if file_storage.authorization.nil?
    if File.file?('client_secrets.json')
      client_secrets = Google::APIClient::ClientSecrets.load
    else
      client_secrets_json = '{
        "web":{
          "auth_uri":"https://accounts.google.com/o/oauth2/auth",
          "client_secret":"' + ENV['CLIENT_SECRET'] + '",
          "token_uri":"https://accounts.google.com/o/oauth2/token",
          "client_email":"' + ENV['CLIENT_EMAIL'] + '",
          "redirect_uris":["' + ENV['REDIRECT_URI'] + '"],
          "client_x509_cert_url":"' + ENV['CLIENT_X509_CERT_URL'] + '",
          "client_id":"' + ENV['CLIENT_ID'] + '",
          "auth_provider_x509_cert_url":"https://www.googleapis.com/oauth2/v1/certs",
          "javascript_origins":["' + ENV['JAVASCRIPT_ORIGIN'] + '"]
        }
      }'

      data = MultiJson.load(client_secrets_json)
      client_secrets = Google::APIClient::ClientSecrets.new(data)
    end

    client.authorization = client_secrets.to_authorization
    client.authorization.scope = [
      'https://www.googleapis.com/auth/fitness.activity.read',
      'https://www.googleapis.com/auth/fitness.activity.write',
      'https://www.googleapis.com/auth/fitness.body.read',
      'https://www.googleapis.com/auth/fitness.body.write',
      'https://www.googleapis.com/auth/fitness.location.read',
      'https://www.googleapis.com/auth/fitness.location.write'
    ]
  else
    client.authorization = file_storage.authorization
  end

  # Since we're saving the API definition to the settings, we're only retrieving
  # it once (on server start) and saving it between requests.
  # If this is still an issue, you could serialize the object and load it on
  # subsequent runs.
  fitness = client.discovered_api('fitness')

  set :logger, logger
  set :api_client, client
  set :fitness, fitness
end

before do
  # Ensure user has authorized the app
  unless user_credentials.access_token || request.path_info =~ /\A\/oauth2/
    redirect to('/oauth2authorize')
  end
end

after do
  # Serialize the access/refresh token to the session and credential store.
  session[:access_token] = user_credentials.access_token
  session[:refresh_token] = user_credentials.refresh_token
  session[:expires_in] = user_credentials.expires_in
  session[:issued_at] = user_credentials.issued_at

  file_storage = Google::APIClient::FileStorage.new(CREDENTIAL_STORE_FILE)
  file_storage.write_credentials(user_credentials)
end

get '/oauth2authorize' do
  # Request authorization
  redirect user_credentials.authorization_uri.to_s, 303
end

get '/oauth2callback' do
  # Exchange token
  user_credentials.code = params[:code] if params[:code]
  user_credentials.fetch_access_token!
  redirect to('/')
end

get '/' do
  # 1 = data sources
  # 2 = heart rate
  # 3 = weight
  call = 3
  start = Time.new(2015, 4, 1)
  now = Time.now.getlocal('+10:00')
  sinceApril1 =  (start.to_i * 1000 * 1000000).to_s + '-' + (now.to_i * 1000 * 1000000).to_s
  since2014 =  (Time.new(2014, 1, 1).to_i * 1000 * 1000000).to_s + '-' + (now.to_i * 1000 * 1000000).to_s

  case call
  when 1
    result = api_client.execute(:api_method => fitness_api.users.data_sources.list,
                                :parameters => {'userId' => 'me'},
                                :authorization => user_credentials)
    return [result.status, {'Content-Type' => 'application/json'}, erb(:index, { :locals => { :resultJson => result.data.to_json } }) ]
  when 2
    result = api_client.execute(:api_method => fitness_api.users.data_sources.datasets.get,
                                :parameters => {
                                  'userId' => 'me',
                                  'dataSourceId' => 'derived:com.google.heart_rate.bpm:com.google.android.gms:merge_heart_rate_bpm',
                                  'datasetId' => sinceApril1
                                },
                                :authorization => user_credentials)
    return [result.status, {'Content-Type' => 'application/json'}, erb(:index, { :locals => { :resultJson => result.data.to_json } }) ]
  when 3
    result = api_client.execute(:api_method => fitness_api.users.data_sources.datasets.get,
                                :parameters => {
                                  'userId' => 'me',
                                  'dataSourceId' => 'derived:com.google.weight:com.google.android.gms:merge_weight',
                                  'datasetId' => since2014
                                },
                                :authorization => user_credentials)
    results = []
    key = 0
    averageSize = 7 # must be odd
    halfAverage = (averageSize - 1) / 2
    dataArray = result.data.point.to_ary
    omissions = []
    movingAverage = nil
    dataArray.each do | item |
      if (key + 1 > halfAverage and key + 1 < dataArray.length - halfAverage) then
        if movingAverage.nil? then
          movingAverage = 0
          for i in (key - halfAverage)..(key + halfAverage)
            movingAverage += dataArray[i].value[0].fp_val.round(2)
          end
          movingAverage = (movingAverage / averageSize).round(2)
        else
          toRemove = key - (halfAverage + 1)
          toAdd = key + halfAverage
          movingAverage = (movingAverage - (results[key - (halfAverage + 1)][:weight] / averageSize) + (dataArray[key + halfAverage].value[0].fp_val.round(2) / averageSize)).round(2)
        end
      end
      # Check if this weight is WAAY off the moving average and omit it
      if not movingAverage.nil? then
        if (item.value[0].fp_val.round(2) - movingAverage).abs > 2 then
          omissions.push(item.start_time_nanos / 1000000)
        end
      end
      hash = { timestamp: item.start_time_nanos / 1000000, weight: item.value[0].fp_val.round(2), movingAverage: movingAverage }
      results.push(hash)
      key = key + 1
    end

    results.reject! { |item| omissions.include?(item[:timestamp]) }

    return [result.status, erb(:weight, { :locals => { :entries => result.data, :results => results } }) ]
  end
end
