require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name           = "react-native-local-tts"
  s.version        = package["version"]
  s.summary        = package["description"]
  s.description    = package["description"]
  s.homepage       = package["homepage"] || "https://github.com/bc-bane/react-native-local-tts"
  s.license        = package["license"] || "MIT"
  s.author         = package["author"] || "bc-bane"

  s.source         = { git: package["repository"]["url"], tag: "v#{s.version}" }
  s.source_files   = "ios/**/*.{swift,h,m}"
  s.requires_arc   = true
  s.static_framework = true

  s.dependency "ExpoModulesCore"

  s.platform      = :ios, "13.0"
  s.swift_version = "5.9"
end
