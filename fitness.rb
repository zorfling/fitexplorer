require 'rubygems'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/file_storage'
require 'sinatra'
require 'logger'
require 'date'

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

def since(theTime)
  now = Time.now.getlocal('+10:00')
  (theTime.to_i * 1000 * 1000000).to_s + '-' + (now.to_i * 1000 * 1000000).to_s
end


get '/' do
  # 1 = data sources
  # 2 = heart rate
  # 3 = weight
  call = 3
  now = Time.now.getlocal('+10:00')
  # start = Time.new(2015, 4, 1)
  # oneMonth = (Date.today - 30).to_time
  # threeMonths = (Date.today - 90).to_time
  sixMonths = (Date.today - 180).to_time
  twelveMonths = (Date.today - 365).to_time
  # yesterday = (Date.today - 1).to_time

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
    startDate = threeMonths
    datasetId = since(startDate)
    result = api_client.execute(:api_method => fitness_api.users.data_sources.datasets.get,
                                :parameters => {
                                  'userId' => 'me',
                                  'dataSourceId' => 'derived:com.google.weight:com.google.android.gms:merge_weight',
                                  'datasetId' => datasetId
                                },
                                :authorization => user_credentials)
    stepResult = api_client.execute(:api_method => fitness_api.users.data_sources.datasets.get,
                                :parameters => {
                                  'userId' => 'me',
                                  'dataSourceId' => 'derived:com.google.step_count.delta:com.google.android.gms:estimated_steps',
                                  'datasetId' => datasetId
                                },
                                :authorization => user_credentials)

    # Set up date list ahead of time to avoid missing days due to no weight recorded
    results = generateDays(startDate, now)
    weight_results = []
    key = 0
    averageSize = 7 # must be odd
    halfAverage = (averageSize - 1) / 2
    dataArray = result.data.point.to_ary
    stepDataArray = stepResult.data.point.to_ary
    omissions = []
    movingAverage = nil
    dataArray.each do | item |
      # actualDate = Time.at(item.start_time_nanos / 1000 / 1000000).to_date
      # checkDate = Date.new(2016, 1, 13)
      # if actualDate == checkDate then
      #   puts item.inspect
      # end
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
          movingAverage = (movingAverage - (weight_results[toRemove][:weight] / averageSize) + (dataArray[toAdd].value[0].fp_val.round(2) / averageSize)).round(2)
        end
      end
      # Check if this weight is WAAY off the moving average and omit it
      if not movingAverage.nil? then
        if (item.value[0].fp_val.round(2) - movingAverage).abs > 2 then
          omissions.push(item.start_time_nanos / 1000000)
        end
      end
      hash = { timestamp: Time.at(item.start_time_nanos / 1000000).utc.localtime.to_i, weight: item.value[0].fp_val.round(2), movingAverage: movingAverage }
      weight_results.push(hash)
      key = key + 1
    end

    stepCounts = {}
    stepDataArray.each do | item |
      steps = item.value[0].intVal
      normalisedDate = Time.at(item.start_time_nanos / 1000000000).utc.localtime.to_date.to_s
      stepCounts[normalisedDate] ||= 0
      stepCounts[normalisedDate] += steps
    end


    results.reject! { |item| omissions.include?(item[:timestamp]) }

    annotations = {
      '2015-11-14' => {
        annotation: 'N',
        annotationText: 'Trip to Sunny Coast'
      },
      '2015-11-21' => {
        annotation: 'G',
        annotationText: 'Started tracking in LifeSum'
      },
      '2015-11-23' => {
        annotation: 'G',
        annotationText: 'Started hitting goals in LifeSum'
      },
      '2015-12-05' => {
        annotation: 'B',
        annotationText: 'Stopped tracking in LifeSum'
      },
      '2015-12-25' => {
        annotation: 'B',
        annotationText: 'Christmas'
      },
      '2015-12-27' => {
        annotation: 'G',
        annotationText: 'Got sick'
      },
      '2015-12-31' => {
        annotation: 'N',
        annotationText: 'Got better'
      },
      '2016-01-04' => {
        annotation: 'N',
        annotationText: 'Back to work'
      },
      '2016-01-12' => {
        annotation: 'B',
        annotationText: 'Lunch with Shen (double lunch)'
      },
      '2016-01-27' => {
        annotation: 'B',
        annotationText: 'Back to Prentice'
      },
      '2016-01-29' => {
        annotation: 'N',
        annotationText: 'Becky starts childcare'
      },
      '2016-01-31' => {
        annotation: 'G',
        annotationText: 'Bouncy Castle'
      },
      '2016-02-05' => {
        annotation: 'B',
        annotationText: 'Beers and start side work'
      },
      '2016-02-14' => {
        annotation: 'B',
        annotationText: 'Up the coast'
      },
      '2016-02-20' => {
        annotation: 'B',
        annotationText: 'Famageddon begins'
      },
      '2016-02-27' => {
        annotation: 'B',
        annotationText: 'Famageddon'
      },
      '2016-03-07' => {
        annotation: 'N',
        annotationText: 'Back to Rock St'
      },
      '2016-03-25' => {
        annotation: 'N',
        annotationText: 'Holidays'
      },
      '2016-03-27' => {
        annotation: 'B',
        annotationText: 'Easter'
      },
      '2016-04-04' => {
        annotation: 'N',
        annotationText: 'Back to work'
      },
      '2016-05-13' => {
        annotation: 'B',
        annotationText: 'Scales broke'
      },
      '2016-06-17' => {
        annotation: 'G',
        annotationText: 'Got Withings'
      },
      '2016-07-12' => {
        annotation: 'B',
        annotationText: 'My birthday'
      },
      '2016-07-16' => {
        annotation: 'N',
        annotationText: 'Finish side work'
      },
      '2016-08-01' => {
        annotation: 'G',
        annotationText: 'Focus on step goal'
      },
      '2017-04-03' => {
        annotation: 'G',
        annotationText: 'Sick'
      },
      '2017-04-16' => {
        annotation: 'B',
        annotationText: 'Easter'
      },
      '2017-04-18' => {
        annotation: 'G',
        annotationText: 'Back to Prentice'
      },
      '2017-05-08' => {
        annotation: 'G',
        annotationText: 'Standing desk!'
      },
      '2017-05-15' => {
        annotation: 'B',
        annotationText: 'Shen week start'
      },
      '2017-05-20' => {
        annotation: 'G',
        annotationText: 'Shen week finish'
      },
      '2017-06-04' => {
        annotation: 'G',
        annotationText: 'Sick'
      },
      '2017-10-24' => {
        annotation: 'G',
        annotationText: 'Start Processed Free Days'
      },
      '2017-10-29' => {
        annotation: 'B',
        annotationText: 'Becky\'s birthday'
      },
      '2018-01-02' => {
        annotation: '?',
        annotationText: 'UQ Extension Begins'
      },
      '2018-03-29' => {
        annotation: '?',
        annotationText: 'Last day at UQ'
      },
      '2018-04-30' => {
        annotation: 'B',
        annotationText: 'Beebs and Becky fly out'
      },
      '2018-05-10' => {
        annotation: 'B',
        annotationText: 'MBP in Apple Store'
      },
      '2018-05-24' => {
        annotation: 'G',
        annotationText: 'MBP back from Apple Store'
      },
      '2018-07-01' => {
        annotation: 'G',
        annotationText: 'Beebs and Becky get back'
      },
      '2018-07-23' => {
        annotation: 'B',
        annotationText: 'First day Equifax'
      },
      '2018-12-14' => {
        annotation: 'G',
        annotationText: 'Holidays from Equifax'
      },
      '2018-10-03' => {
        annotation: 'G',
        annotationText: 'Start Noom'
      },
      '2018-12-25' => {
        annotation: 'B',
        annotationText: 'Christmas'
      }
    }

    # Add weights
    normalisedWeights = {}
    weight_results.map! do |elem|
      timestamp = elem[:timestamp]
      normalisedDate = Time.at(timestamp / 1000).utc.localtime.to_date
      normalisedWeights[normalisedDate.to_s] = elem
    end

    # Add annotations
    previous_weight = 0
    previous_average = 0
    results.map! do |elem|
      timestamp = elem[:timestamp]
      normalisedDate = Time.at(timestamp / 1000).utc.localtime.to_date
      # puts normalisedDate

      if (annotations.has_key? normalisedDate.to_s) then
        elem[:annotation] = annotations[normalisedDate.to_s][:annotation]
        elem[:annotationText] = annotations[normalisedDate.to_s][:annotationText]
      end

      if (stepCounts.has_key? normalisedDate.to_s) then
        elem[:steps] = stepCounts[normalisedDate.to_s]
      end

      if (normalisedWeights.has_key? normalisedDate.to_s) then
        elem[:weight] = normalisedWeights[normalisedDate.to_s][:weight]
        elem[:movingAverage] = normalisedWeights[normalisedDate.to_s][:movingAverage]
        previous_weight = elem[:weight]
        previous_average = elem[:movingAverage]
      else
        # makes for a neater graph if we just fudge missing values to yesterdays
        elem[:weight] = previous_weight
        elem[:movingAverage] = previous_average
      end

      elem
    end


    return [result.status, erb(:weight, { :locals => { :entries => result.data, :results => results, :startDate => startDate } }) ]
  end
end

def generateDays(from, to)
  results = []
  current = from.to_date
  to_timestamp = to.to_date.to_time.to_i
  while current.to_time.to_i <= to_timestamp do
    hash = { timestamp: current.to_time.utc.localtime.to_i * 1000 }
    results.push(hash)
    current = current + 1
  end
  results
end
