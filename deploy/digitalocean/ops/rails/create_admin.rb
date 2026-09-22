login, first, last, mail = ARGV
u = User.new(login:, firstname: first, lastname: last, mail:, admin: true, status: :active, language: "en")
u.password = u.password_confirmation = ENV.fetch("OP_SECRET")
if u.save
  puts "created #{u.login}, admin=#{u.admin?}, status=#{u.status}"
else
  $stderr.puts "not created: #{u.errors.full_messages.join('; ')}"
  exit 1
end
