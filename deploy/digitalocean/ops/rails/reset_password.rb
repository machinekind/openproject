u = User.find_by(login: ARGV[0]) or abort("no user with login #{ARGV[0]}")
u.password = u.password_confirmation = ENV.fetch("OP_SECRET")
u.force_password_change = false
u.failed_login_count = 0
if u.save
  Rack::Attack::Allow2Ban.reset("login:#{u.login.downcase}", maxretry: 20, findtime: 60, bantime: 1800)
  puts "password reset for #{u.login}, admin=#{u.admin?}, status=#{u.status}"
else
  $stderr.puts "not changed: #{u.errors.full_messages.join('; ')}"
  exit 1
end
