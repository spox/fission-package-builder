use_inline_resources if self.respond_to?(:use_inline_resources)

def load_current_resource
  new_resource.version '1.0' unless new_resource.version
  new_resource.package_name new_resource.name unless new_resource.package_name
  unless(new_resource.package)
    new_resource.package ::File.join(node[:fpm_tng][:package_dir], "#{new_resource.name}-#{new_resource.version}.#{new_resource.output_type}")
  end
  new_resource.workdir node[:fpm_tng][:build_dir] unless new_resource.workdir
  new_resource.creates new_resource.package unless new_resource.creates
  if(node[:fpm_tng][:bundle][:enable])
    node.set[:fpm_tng][:exec] = ::File.join(node[:fpm_tng][:bundle][:directory], 'bin/fpm')
  end
  # Use default from node attribute if node attribute is set
  %w(vendor maintainer).each do |k|
    unless(new_resource.send(k))
      if(node[:fpm_tng][k])
        new_resource.send(k, node[:fpm_tng][k])
      end
    end
  end
end

action :create do
  unless(::File.exists?(new_resource.creates))
    fpm = [node[:fpm_tng][:exec]]
    fpm << "-s #{new_resource.input_type}"
    fpm << "-t #{new_resource.output_type}"
    fpm << "-C #{new_resource.chdir}" if new_resource.chdir
    fpm << "-n #{new_resource.package_name}"
    fpm << "--verbose"

    [FpmTng::STRINGS, FpmTng::NUMERICS].flatten.compact.each do |str|
      if(new_resource.send(str))
        string = new_resource.send(str).to_s
        string = "\"#{string}\"" if string.include?(' ')
        fpm << "--#{str.gsub('_', '-')} #{string}"
      end
    end

    FpmTng::STRING_ARRAYS.each do |thing|
      Array(new_resource.send(thing)).each do |str|
        string = str
        string = "\"#{str}\"" if str.include?(' ')
        fpm << "--#{thing.gsub('_', '-')} #{string}"
      end
    end

    FpmTng::TRUE_FALSE.each do |bool|
      if(new_resource.send(bool))
        fpm << "--#{bool.gsub('_', '-')}"
      elsif(new_resource.send(bool) == false)
        fpm << "--no-#{bool.gsub('_', '-')}"
      end
    end

    fpm << "#{Array(new_resource.input_args).join(' ')}"

    unbundle do
      execute "Build package - #{new_resource.name}!" do
        command fpm.join(' ')
        creates new_resource.package
        cwd '/tmp'
      end
    end
  end

  if(new_resource.reprepro)
    reprepro_deb new_resource.name do
      package new_resource.package
    end
  end

  if(new_resource.repository)
    repository_package new_resource.package do
      repository new_resource.repository
    end
  end
end

# TODO: Remove from reprepro?
action :delete do
  file new_resource.package do
    action :delete
  end
end

# Break out of the bundle if in one (generally a development issue)
def unbundle
  if(defined?(Bundler))
    Chef::Log.warn "Unbundling and running directly because bundler is a jerk"
    e_r = yield
    e_r.action :nothing
    Bundler.with_clean_env do
      unless(system(e_r.command))
        raise Mixlib::ShellOut::ShellCommandFailed.new("Unbundled fpm packaging failed")
      else
        new_resource.updated_by_last_action(true)
      end
    end
  else
    yield
  end
end
