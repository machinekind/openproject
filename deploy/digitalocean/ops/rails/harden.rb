# Lock the seeded "admin" account once another active administrator exists.
seeded = User.find_by(login: "admin")
others = User.active.admin.where.not(login: "admin")
if seeded.nil?
  puts "no seeded admin account present"
elsif others.none?
  abort "refusing: 'admin' is the only active administrator. Create a personal one first (make create-admin)."
elsif seeded.locked?
  puts "'admin' is already locked; administrators: #{others.pluck(:login).join(', ')}"
else
  seeded.update_columns(status: User.statuses[:locked])
  puts "'admin' locked; administrators: #{others.pluck(:login).join(', ')}"
end
