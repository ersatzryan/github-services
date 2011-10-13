require 'mustache'

class Service::Email < Service

  string :address, :secret, :subject_format
  boolean :send_from_author

  def first_commit
    payload['commits'].first
  end

  def first_commit_sha
    first_commit["id"][0..5]
  end

  def first_commit_title
    title = first_commit["message"][/^([^\n]+)/, 1] || ''
    title.length > 50 ? "#{title.slice(0,50)}..." : title
  end

  def receive_push
    body = <<-EOH
  Branch: #{payload['ref']}
  Home:   #{payload['repository']['url']}

  EOH

    payload['commits'].each do |commit|
      gitsha   = commit['id']
      added    = commit['added'].map    { |f| ['A', f] }
      removed  = commit['removed'].map  { |f| ['R', f] }
      modified = commit['modified'].map { |f| ['M', f] }

      changed_paths = (added + removed + modified).sort_by { |(char, file)| file }
      changed_paths = changed_paths.collect { |entry| entry * ' ' }.join("\n  ")

      timestamp = Date.parse(commit['timestamp'])

      body << <<-EOH
  Commit: #{gitsha}
      #{commit['url']}
  Author: #{commit['author']['name']} <#{commit['author']['email']}>
  Date:   #{timestamp} (#{timestamp.strftime('%a, %d %b %Y')})

  EOH

      if changed_paths.size > 0
        body << <<-EOH
  Changed paths:
    #{changed_paths}

  EOH
      end

      body << <<-EOH
  Log Message:
  -----------
  #{commit['message']}


  EOH
    end

    body << "Compare: #{payload['compare']}" if payload['commits'].size > 1
    commit = payload['commits'].last # assume that the last committer is also the pusher

    begin
      message = TMail::Mail.new
      message.set_content_type('text', 'plain', {:charset => 'UTF-8'})
      message.from = "#{commit['author']['name']} <#{commit['author']['email']}>" if data['send_from_author']
      message.reply_to = "#{commit['author']['name']} <#{commit['author']['email']}>" if data['send_from_author']
      message.to      = data['address']
      message.subject = subject_line
      message.body    = body
      message.date    = Time.now

      message['Approved'] = data['secret'] if data['secret'].to_s.size > 0

      if data['send_from_author']
        send_message message, "#{commit['author']['name']} <#{commit['author']['email']}>", data['address']
      else
        send_message message, "GitHub <noreply@github.com>", data['address']
      end
    end
  end

  def subject_line
    begin
      sub = Mustache.render(data["subject_format"], self) if data["subject_format"]
      sub || default_subject_line
    rescue Mustache::Parser::SyntaxError
      default_subject_line
    end
  end

  def default_subject_line
    "[#{name_with_owner}] #{first_commit_sha}: #{first_commit_title}"
  end

  def smtp_settings
    @smtp_settings ||= begin
      args = [ email_config['address'], (email_config['port'] || 25).to_i, (email_config['domain'] || 'localhost.localdomain') ]
      if email_config['authentication']
        args.push email_config['user_name'], email_config['password'], email_config['authentication']
      end
      args
    end
  end

  def send_message(message, from, to)
    Net::SMTP.start(*smtp_settings) do |smtp|
      smtp.send_message message.to_s, from, to
    end
  rescue Net::SMTPSyntaxError, Net::SMTPFatalError
    raise_config_error "Invalid email address"
  end
end
