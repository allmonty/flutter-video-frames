#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint video_frames.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'video_frames'
  s.version          = '1.1.0'
  s.summary          = 'Decode video to RGBA frames and encode RGBA frames to H.264 or HEVC MP4.'
  s.description      = <<-DESC
Frame-by-frame video decoding and encoding with AVFoundation.
                       DESC
  s.homepage         = 'https://github.com/allmonty/flutter-video-frames'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Allan Monteiro' => 'allanbrados@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'video_frames/Sources/video_frames/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.frameworks = 'Accelerate', 'AVFoundation', 'CoreMedia', 'CoreVideo'

  # Flutter.framework does not contain a i386 slice, which is specific to iOS.
  s.ios.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.osx.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'video_frames_privacy' => ['video_frames/Sources/video_frames/PrivacyInfo.xcprivacy']}
end
