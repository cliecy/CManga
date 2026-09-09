Pod::Spec.new do |s|
  s.name = 'VeneraOnnxRuntime'
  s.version = '1.29.0'
  s.summary = 'Pinned native ONNX Runtime WebGPU with hardware-only Dawn Metal.'
  s.homepage = 'https://github.com/microsoft/onnxruntime'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Microsoft and Venera contributors'
  s.source = { :git => 'https://github.com/microsoft/onnxruntime.git', :commit => '2e2543fbe9fae542f921d47a72d21d5a4ef0b710' }
  s.ios.deployment_target = '16.3'
  s.osx.deployment_target = '13.3'
  s.vendored_frameworks = 'onnxruntime.xcframework'
  s.preserve_paths = 'build-identity.json', 'dependencies.txt', 'ThirdPartyNotices.txt', 'Headers'
  s.frameworks = 'Foundation', 'Metal', 'QuartzCore', 'IOSurface', 'Network'
  s.osx.frameworks = 'IOKit'
  s.libraries = 'c++'
end
