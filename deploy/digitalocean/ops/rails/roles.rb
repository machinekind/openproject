# A global role for team leads, and Project admin for whoever creates a project.
name = ARGV[0] || "Moderator"
wanted = %i[add_project create_user manage_placeholder_user view_all_principals]
role = GlobalRole.find_or_initialize_by(name:)
role.permissions = (role.permissions | wanted)
role.save!
puts "global role '#{role.name}' (id #{role.id}): #{role.permissions.sort.join(', ')}"

creator_role = ProjectRole.find_by(name: "Project admin")
if creator_role
  Setting.new_project_user_role_id = creator_role.id
  puts "project creators receive '#{creator_role.name}'"
else
  puts "no 'Project admin' role found; set the creator role under Administration, Projects, Settings"
end
