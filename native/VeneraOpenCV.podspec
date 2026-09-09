# The upstream 4.11.0 Package.swift supplies this archive checksum and linkage.
# Its build recipe compiles OpenCV source for iOS arm64, arm64/x86_64 simulator,
# and arm64/x86_64 macOS. Unlike the obsolete OpenCV CocoaPod, it is an XCFramework.
Pod::Spec.new do |s|
  s.name = 'VeneraOpenCV'
  s.version = '4.11.0'
  s.summary = 'Pinned OpenCV Apple XCFramework from the opencv-spm distribution.'
  s.homepage = 'https://github.com/yeatse/opencv-spm'
  s.license = { :type => 'Apache-2.0' }
  s.author = 'OpenCV contributors; opencv-spm packagers'
  s.source = {
    :http => 'https://github.com/yeatse/opencv-spm/releases/download/4.11.0/opencv2.xcframework.zip',
    :sha256 => '4b1e76f3d1ce19369ff7e151d1c564926b4d23b5515c62fc65517dfd395c3929'
  }
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.13'
  # ZIP extraction preserves the upstream build/ directory.
  s.vendored_frameworks = 'build/opencv2.xcframework'
  s.libraries = 'c++'
  s.frameworks = 'AVFoundation', 'CoreImage', 'CoreMedia', 'Accelerate'
  s.ios.frameworks = 'CoreVideo'
  s.osx.frameworks = 'OpenCL'
end
