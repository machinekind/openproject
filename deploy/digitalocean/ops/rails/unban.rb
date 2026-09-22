login = ARGV[0].to_s.downcase
Rack::Attack::Allow2Ban.reset("login:#{login}", maxretry: 20, findtime: 60, bantime: 1800)
User.where(login:).update_all(failed_login_count: 0)
puts "login block cleared for #{login}"
