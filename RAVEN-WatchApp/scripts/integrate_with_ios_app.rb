#!/usr/bin/env ruby
# integrate_with_ios_app.rb
#
# Adds the RAVEN-Watch app as an embedded target inside the iOS
# `RAVEN.xcodeproj`. After this runs (once), building the iOS app
# produces an `.app` bundle with the Watch app embedded at
# `Payload/RAVEN.app/Watch/RAVEN.app`. App Store Connect then offers
# the user "auto-install on Apple Watch" on first install — the
# standard Apple Watch app delivery flow.
#
# Idempotent: if a target named "RAVEN-Watch" already exists, the
# script exits without changes. Re-running after edits to the Watch
# source folder is safe (file refs get re-added).
#
# Backup the iOS `.pbxproj` before running. The script also writes
# its own `.pbxproj.pre-watch-target-backup` once on first edit.

require 'xcodeproj'
require 'fileutils'

IOS_PROJECT = "/Users/ahmd/hybrid_messenger/ios-native/RAVEN/RAVEN.xcodeproj"
WATCH_TARGET_NAME = "RAVEN-Watch"
WATCH_BUNDLE_ID = "app.raven.ios.watchkitapp"
WATCH_DEV_TEAM = "72QQ5Q324C"

# Path to the watchOS source folder, expressed relative to the iOS
# `.xcodeproj`'s parent directory (`ios-native/RAVEN/`). Resolves to
# `/Users/ahmd/hybrid_messenger/RAVEN-WatchApp/RAVEN-Watch`.
WATCH_SRC_REL = "../../RAVEN-WatchApp/RAVEN-Watch"

abort "iOS project not found at #{IOS_PROJECT}" unless Dir.exist?(IOS_PROJECT)

project = Xcodeproj::Project.open(IOS_PROJECT)

if project.targets.any? { |t| t.name == WATCH_TARGET_NAME }
  puts "✓ Watch target '#{WATCH_TARGET_NAME}' already present — nothing to do."
  exit 0
end

# Write a backup before any mutation so the user can restore.
backup = "#{IOS_PROJECT}/project.pbxproj.pre-watch-target-backup"
unless File.exist?(backup)
  FileUtils.cp("#{IOS_PROJECT}/project.pbxproj", backup)
  puts "↳ backup written to #{backup}"
end

# 1. Create the watchOS application target. Modern single-target
#    watchOS apps use the regular `application` product type with
#    `SDKROOT=watchos`; no separate Watch Extension is needed.
watch_target = project.new_target(
  :application, WATCH_TARGET_NAME, :watchos, "10.0", project.products_group
)

# 2. Configure build settings. These mirror the standalone
#    `RAVEN-WatchApp/project.yml` so the integrated target builds the
#    same way as the standalone one.
shared = {
  "PRODUCT_NAME"                  => "RAVEN",
  "PRODUCT_BUNDLE_IDENTIFIER"     => WATCH_BUNDLE_ID,
  "WATCHOS_DEPLOYMENT_TARGET"     => "10.0",
  "SWIFT_VERSION"                 => "5.0",
  "DEVELOPMENT_TEAM"              => WATCH_DEV_TEAM,
  "CODE_SIGN_STYLE"               => "Automatic",
  "TARGETED_DEVICE_FAMILY"        => "4",
  "SDKROOT"                       => "watchos",
  "SUPPORTS_MACCATALYST"          => "NO",
  "INFOPLIST_FILE"                => "#{WATCH_SRC_REL}/Resources/Info.plist",
  "CODE_SIGN_ENTITLEMENTS"        => "#{WATCH_SRC_REL}/Resources/RAVEN-Watch.entitlements",
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "GENERATE_INFOPLIST_FILE"       => "NO",
  "SKIP_INSTALL"                  => "NO",
  "DEAD_CODE_STRIPPING"           => "YES",
  "ENABLE_PREVIEWS"               => "YES",
}
watch_target.build_configurations.each { |cfg| cfg.build_settings.merge!(shared) }

# 3. Create a group that mirrors the on-disk source layout. The group
#    is a *folder reference* with `path = WATCH_SRC_REL`, so any file
#    we add inside it uses paths relative to the source folder root.
xcodeproj_dir = File.dirname(IOS_PROJECT)
watch_src_abs = File.expand_path(WATCH_SRC_REL, xcodeproj_dir)
abort "Watch source folder not found at #{watch_src_abs}" unless Dir.exist?(watch_src_abs)

watch_group = project.main_group.new_group(WATCH_TARGET_NAME, WATCH_SRC_REL, '<group>')

# 4. Walk the source tree and add every `.swift` file to the
#    target's compile phase. Resources are added separately.
sources_phase = watch_target.source_build_phase

Dir.glob(File.join(watch_src_abs, "**", "*.swift")).sort.each do |abs_path|
  rel = abs_path.sub("#{watch_src_abs}/", "")
  # Build a chain of subgroups inside `watch_group` for the file's
  # directory components, then attach the file ref to the leaf.
  parts = rel.split(File::SEPARATOR)
  filename = parts.pop
  parent = parts.reduce(watch_group) do |g, segment|
    g.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == segment } \
      || g.new_group(segment, segment, '<group>')
  end
  file_ref = parent.new_file(filename)
  sources_phase.add_file_reference(file_ref)
end

# 5. Resources — Info.plist + entitlements are referenced by the
#    build settings above (INFOPLIST_FILE / CODE_SIGN_ENTITLEMENTS),
#    so they only need a file ref so the IDE can show them. The asset
#    catalog must additionally be in the Resources build phase.
resources_phase = watch_target.resources_build_phase

res_group = watch_group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == "Resources" }
res_group ||= watch_group.new_group("Resources", "Resources", '<group>')

["Info.plist", "RAVEN-Watch.entitlements"].each do |name|
  unless res_group.children.any? { |c| c.display_name == name }
    res_group.new_file(name)
  end
end

assets_path = "Assets.xcassets"
unless res_group.children.any? { |c| c.display_name == assets_path }
  assets_ref = res_group.new_file(assets_path)
  resources_phase.add_file_reference(assets_ref)
else
  assets_ref = res_group.children.find { |c| c.display_name == assets_path }
  unless resources_phase.files_references.include?(assets_ref)
    resources_phase.add_file_reference(assets_ref)
  end
end

# 6. Make the iOS RAVEN target embed the Watch target. This is the
#    "Embed Watch Content" build phase that Xcode adds via
#    File → New → Target. App Store Connect uses this to surface the
#    Watch app as an auto-install companion.
ios_target = project.targets.find { |t| t.name == "RAVEN" }
abort "Main iOS target 'RAVEN' not found in project" unless ios_target

ios_target.add_dependency(watch_target)

embed_phase = ios_target.copy_files_build_phases.find { |ph| ph.name == "Embed Watch Content" }
unless embed_phase
  embed_phase = ios_target.new_copy_files_build_phase("Embed Watch Content")
  # Spec 16 = "Products Directory" with dst_path interpreted as a
  # subpath of the wrapper. This is the exact spec Xcode generates
  # for embedded watchOS apps as of Xcode 15.
  embed_phase.dst_subfolder_spec = "16"
  embed_phase.dst_path = "$(CONTENTS_FOLDER_PATH)/Watch"
end

watch_product = watch_target.product_reference
unless embed_phase.files_references.include?(watch_product)
  build_file = embed_phase.add_file_reference(watch_product)
  # `CodeSignOnCopy` + `RemoveHeadersOnCopy` are the standard attrs
  # Xcode applies to embedded watch products.
  build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
end

# 7. Save.
project.save
puts "✓ Added '#{WATCH_TARGET_NAME}' target and Embed Watch Content phase."
puts "  Bundle id:  #{WATCH_BUNDLE_ID}"
puts "  Source:     #{WATCH_SRC_REL}"
puts "  Open the project in Xcode and build to verify."
