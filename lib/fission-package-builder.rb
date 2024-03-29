require 'fission'
require 'fission-package-builder/version'
require 'fission-package-builder/builder'
require 'fission-package-builder/formatter'

Fission.service(
  :package_builder,
  :configuration => {
    :environment => {
      :description => 'Custom environment variables',
      :type => :hash
    }
  }
)
