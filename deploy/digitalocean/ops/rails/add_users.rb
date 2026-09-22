# Reads "login,first name,last name,email" lines from stdin. Prints a temporary password per user.
require "securerandom"
failed = 0
$stdin.each_line do |line|
  login, first, last, mail = line.strip.split(",").map { |v| v.to_s.strip }
  next if login.to_s.empty? || login.start_with?("#")
  pw = "Tmp-#{SecureRandom.alphanumeric(14)}9a%"
  u = User.new(login:, firstname: first, lastname: last, mail:, status: :active, language: "en")
  u.password = u.password_confirmation = pw
  u.force_password_change = true
  if u.save
    puts "OK    #{login}  #{pw}"
  else
    failed += 1
    puts "FAIL  #{login}: #{u.errors.full_messages.join('; ')}"
  end
end
exit 1 if failed.positive?
