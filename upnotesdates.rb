require 'sinatra'
enable :sessions
enable :lock

require 'oauth'
require 'oauth/consumer'

# Load Thrift & Evernote Ruby libraries
require "evernote_oauth"

##
# Verify that you have obtained an Evernote API key
##
before do
  if ENV['OAUTH_CONSUMER_KEY'].empty? || ENV['OAUTH_CONSUMER_SECRET'].empty?
    halt '<span style="color:red">Before using this sample code you must provide env variables OAUTH_CONSUMER_KEY and OAUTH_CONSUMER_SECRET with the values that you received from Evernote. If you do not have an API key, you can request one from <a href="http://dev.evernote.com/documentation/cloud/">dev.evernote.com/documentation/cloud/</a>.</span>'
  end
end

helpers do
  def auth_token
    session[:access_token].token if session[:access_token]
  end

  def client
    @client ||= EvernoteOAuth::Client.new(token: auth_token, consumer_key:ENV['OAUTH_CONSUMER_KEY'], consumer_secret:ENV['OAUTH_CONSUMER_SECRET'], sandbox: false)
  end

  def note_store
    @note_store ||= client.note_store
  end

end

##
# Index page
##
get '/' do
  erb :index
end

##
# Reset the session
##
get '/reset' do
  session.clear
  redirect '/'
end

##
# Obtain temporary credentials
##
get '/requesttoken' do
  callback_url = request.url.chomp("requesttoken").concat("callback")
  session[:request_token] = client.request_token(:oauth_callback => callback_url)
  redirect '/authorize'
end

##
# Redirect the user to Evernote for authoriation
##
get '/authorize' do
  if session[:request_token]
    redirect session[:request_token].authorize_url
  else
    # You shouldn't be invoking this if you don't have a request token
    raise "Request token not set."
  end
end

##
# Receive callback from the Evernote authorization page
##
get '/callback' do
  unless params['oauth_verifier'] || session['request_token']
    raise "Content owner did not authorize the temporary credentials"
  end
  session[:oauth_verifier] = params['oauth_verifier']
  session[:access_token] = session[:request_token].get_access_token(:oauth_verifier => session[:oauth_verifier])
  redirect '/'
end

def get_date note
  return nil unless note
  datestr = nil
  datestr = $1 if !datestr && note.content =~ /Date Received:[strongspan<>\/]+\W*([0-9][^\<]+)<\/span/
  datestr = $1 if !datestr && note.content =~ /Date Received:<\/b>\W*([0-9][^\<]+)<br/
  if datestr
    enm = %w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    rum = %w(января февраля марта апреля мая июня июля августа сентября октября ноября декабря)
    enm.zip(rum).each { |en,ru| datestr.gsub!(ru,en) }
    datestr = datestr.gsub('г. ','').strip
    DateTime.strptime(datestr + " MSK", "%d %b %Y %H:%M %Z")
  end
end

##
# Request tag named 'done'
##
def get_tag_done
  begin
    tags = note_store.listTags(auth_token)
  rescue ::Evernote::EDAM::Error::EDAMSystemException => e
    puts "Got timeout exception for #{e.rateLimitDuration / 60} minutes: #{e.inspect}"
    raise
  end
  tag_done = tags.find { |t| t.name == 'done' }
  raise 'No tag found' unless tag_done
  tag_done
end

##
# Update notes created/modified date for notes imported from iCloud notes
##
def fix_notes
  tag_done = get_tag_done

  # what to filter
  filter = Evernote::EDAM::NoteStore::NoteFilter.new
  filter.words = 'Date Received:'
  filter.order = Evernote::EDAM::Type::NoteSortOrder::TITLE

  # what to get
  spec = Evernote::EDAM::NoteStore::NotesMetadataResultSpec.new
  spec.includeTitle = spec.includeCreated = spec.includeUpdated = spec.includeTagGuids = true

  offset = 0
  ind = 0
  while true do
    puts "\nRequesting notes from offset #{offset}"
    notes_metadata = note_store.findNotesMetadata(filter, offset, Evernote::EDAM::Limits::EDAM_USER_NOTES_MAX-1, spec)
    puts "Got #{notes_metadata.notes.size}, start #{notes_metadata.startIndex}, total #{notes_metadata.totalNotes}"
    if notes_metadata.notes.empty? || offset >= notes_metadata.totalNotes
      puts "No more notes"
      break
    end
    offset += notes_metadata.notes.size    
    
    # Iterate for notes metadata
    notes_metadata.notes.each do |note_meta|
      if note_meta.tagGuids.include?(tag_done.guid)
        puts "Skipping done note: #{note_meta.title}"
        next
      end
      begin
        note = note_store.getNote(note_meta.guid, true, false, false, false)
        raise 'Failed to get note' unless note
        date = get_date(note)
        if date
          puts "For note #{note.title} created #{Time.at(note.created/1000)}, changing to #{date}"
          note.created = note.updated = date.to_time.utc.to_i * 1000
          note.tagGuids << tag_done.guid
          note_store.updateNote(note)
        else
          puts 'Failed to get date from note: ' + note.title
        end
      rescue ::Evernote::EDAM::Error::EDAMSystemException => e
        puts "Got timeout exception for #{e.rateLimitDuration / 60} minutes: #{e.inspect}"
        sleep(e.rateLimitDuration + 10)
      end
      ind += 1
      sleep((ind % 10) == 0 ? 5 : 1)
    end
  end
end

post '/upnotesdates' do
  begin
    fix_notes
  rescue => e
    puts "Got exception: #{e.inspect}"
    raise
  end
  erb :index
end

__END__

@@ index
<html>
<head>
  <title>Update notes dates</title>
</head>
<body>
  <a href="/requesttoken">Click here</a> to authenticate this application using OAuth.
  <br/>
  <form action='/upnotesdates' method='post'>
    <input type='submit' value="Update notes" />
  </form>
</body>
</html>
