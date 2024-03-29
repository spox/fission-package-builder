require 'fission/callback'
require 'fission-package-builder/errors'
require 'fission-package-builder/packager'
require 'fission-package-builder/formatter'
require 'fission-assets'
require 'fission-assets/packer'

module Fission
  module PackageBuilder
    class Builder < Fission::Callback

      DEFAULT_PLATFORM = 'ubuntu_1404'
      DEFAULT_PACKAGE = 'deb'
      DEFAULT_UBUNTU_VERSION = '14.04'

      # Validity of message for processing
      #
      # @return [Truthy, Falsey]
      def valid?(message)
        super do |payload|
          payload.get(:data, :package_builder, :code_asset)
        end
      end

      # Build new packages!
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          keepalive = nil
          begin
            keepalive = every(10){ message.touch! }
            copy_path = repository_copy(payload[:message_id], payload.get(:data, :package_builder, :code_asset))
            base_config = load_config(copy_path)
            if(base_config[:target])
              base_config = Smash.new(
                :default => base_config
              )
            end
            begin
              begin
                base_config.each do |key, config|
                  next if config.nil? || config.empty?
                  info "Starting build for <#{key}> on #{message}"
                  chef_json = build_chef_json(config, payload, copy_path)
                  load_history_assets(config, payload)
                  start_build(payload[:message_id], chef_json, config[:target])
                  store_packages(payload, config[:target])
                end
              ensure
                begin
                  log_file_path = File.join(workspace(payload[:message_id], :log), "#{payload[:message_id]}.log")
                  if(File.exists?(log_file_path))
                    key = File.join('package_builder', "#{payload[:message_id]}.log")
                    asset_store.put(key, File.open(log_file_path, 'r'))
                    payload.set(:data, :package_builder, :logs, :output, key)
                  end
                rescue => e
                  error "Failed to persist log data for message #{message}: #{e.class} - #{e}"
                  debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
                end
              end
              job_completed(:package_builder, payload, message)
            rescue => e
              error "Builder failed #{message}: #{e.class}: #{e}"
              debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
              run_error = extract_chef_stacktrace(payload)
              failed(payload, message, run_error || e.message)
            end
          rescue => e
            error "Unknown failure encountered #{message}: #{e.class}: #{e}"
            debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
            failed(payload, message, e.message)
          ensure
            keepalive.cancel
          end
        end
      end

      # config:: packager config
      # payload:: Payload
      # Retrieve previous versions from asset store and add to history
      def load_history_assets(config, payload)
        if(versions = config.get(:build, :history, :versions))
          versions = [versions].flatten.compact.uniq
          ext = config.get(:target, :package)
          versions.each do |version|
            filename = "#{payload[:data][:package_builder][:name]}-#{version}.deb"
            key = generate_key(payload, filename)
            begin
              package = asset_store.get(key)
              File.open(history = File.join(workspace(payload[:message_id], :history), filename), 'wb') do |file|
                while(bytes = package.read(2048))
                  file.write bytes
                end
              end
              info "Wrote history asset -> #{history}"
            rescue Fission::Assets::Error::NotFound => e
              warn "Failed to load historical package asset: #{e}"
            end
          end
        end
      end

      # payload:: payload
      # file:: File name or path
      # Generate the asset store key based on file and payload
      def generate_key(payload, file)
        key = [
          'packages',
          payload.get(:data, :account, :name),
          File.basename(file)
        ].compact.join('/')
      end

      # payload:: Payload
      # target:: Target description hash
      # Store packages into private data store
      def store_packages(payload, target)
        keys = Dir.glob(File.join(workspace(payload[:message_id], :packages), '*')).map do |file|
          key = generate_key(payload, file)
          asset_store.put(key, File.open(file, 'rb'))
          File.delete(file)
          key
        end
        payload[:data][:package_builder][:keys] ||= []
        payload[:data][:package_builder][:categorized] ||= {}
        payload[:data][:package_builder][:keys] += keys
        payload[:data][:package_builder][:categorized].merge!(
          target[:platform] => {
            target[:version] => keys
          }
        )
        true
      end

      # repo_path:: Path to repository on local sytem
      # Returns hash'ed configuration file
      #
      # @param repo_path [String]
      # @return [Smash]
      def load_config(repo_path)
        result = nil
        file_path = File.join(repo_path, Packager.file_name)
        ephemeral = nil
        begin
          result = Packager.json_load(file_path)
          unless(result)
            ephemeral = remote_process
            ephemeral.push_file(
              StringIO.new(Packager.wrapper_file),
              '/tmp/pkgr.rb'
            )
            ephemeral.push_file(File.open(file_path, 'r'), '/tmp/packager')
            result = ephemeral.exec!('ruby -r/tmp/pkgr.rb -C/tmp /tmp/packager')
            remote_file_path = result.output.read.strip
            result = ephemeral.get_file(remote_file_path)
            if(result.is_a?(String))
              result = MultiJson.load(result)
            end
            result = result.to_smash
          end
        rescue => e
          error "Failed to load configuration file: #{repo_path}/#{Packager.file_name} - #{e.class}: #{e.message}"
          if(e.respond_to?(:result))
            error "Failure reason: #{e.result.output}"
          end
          debug "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
          raise 'Failed to load configuration file!'
        ensure
          ephemeral.terminate if ephemeral
        end
        result
      end

      # config:: build config hash
      # params:: payload
      # target_store:: location to store built packages
      # Build the JSON for our chef run
      def build_chef_json(config, params, target_store)
        unless(config[:build][:version])
          if(params.get(:data, :code_fetcher, :info, :reference).include?('tag') ||
              params.get(:data, :code_fetcher, :info, :reference) == params.get(:data, :code_fetcher, :info, :commit_sha)
          )
            config[:build][:version] = params.get(:data, :code_fetcher, :info, :reference).sub('refs/tags/', '')
          else
            config[:build][:version] = Time.now.strftime('%Y%m%d%H%M%S')
          end
        end
        params[:data][:package_builder][:name] = config[:build][:name] || params.get(:data, :code_fetcher, :info, :name)
        params[:data][:package_builder][:version] = config[:build][:version]
        config[:build][:version] = config[:build][:version].gsub(/^[^\d]*/, '')
        unless(config.get(:target, :package))
          config.set(:target, :package, DEFAULT_PACKAGE)
        end
        JSON.dump(
          :packager => {
            :build => config.merge(
              :target_store => target_store,
              :history_directory => workspace(params[:message_id], :history)
            ),
            :environment => {
              'PACKAGER_HISTORY_DIR' => workspace(params[:message_id], :history),
              'PACKAGER_NAME' => config[:build][:name],
              'PACKAGER_INSTALL_PREFIX' => config[:build][:install_prefix],
              'PACKAGER_TYPE' => config[:target][:package],
              'PACKAGER_VERSION' => config[:build][:version],
              'PACKAGER_COMMIT_SHA' => params.get(:data, :code_fetcher, :info, :commit_sha),
              'PACKAGER_PUSHER_NAME' => params.get(:data, :code_fetcher, :info, :owner),
              'PACKAGER_PUSHER_EMAIL' => params.get(:data, :code_fetcher, :info, :push_email)
            }.merge(config.fetch(:environment, {}))
          },
          :fpm_tng => {
            :package_dir => workspace(params[:message_id], :packages),
            :build_dir => workspace(params[:message_id], :fpm)
          },
          :run_list => ['recipe[packager]']
        )
      end

      # uuid:: unique ID (message id)
      # json:: chef json
      # base:: base container for ephemeral
      # Start the build
      def start_build(uuid, json, base={})
        if(base[:platform])
          base = "#{base[:platform]}_#{base.fetch(:version, DEFAULT_UBUNTU_VERSION).gsub('.', '')}"
        else
          base = DEFAULT_PLATFORM
        end
        json_path = File.join(workspace(uuid, :first_runs), "#{uuid}.json")
        File.open(json_path, 'w') do |f|
          f.puts json
        end
        log_file_path = File.join(workspace(uuid, :log), "#{uuid}.log")
        command = [chef_exec_path, '-j', json_path, '-c', write_solo_config(uuid), '-L', log_file_path, '--force-logger']
        ephemeral = remote_process(:image => base)
        w_space = Fission::Assets::Packer.pack(workspace(uuid))
        ephemeral.push_file(w_space, '/tmp/workspace.zip')
        ephemeral.exec!("mkdir -p #{workspace(uuid)}")
        ephemeral.exec!("unzip /tmp/workspace.zip -d #{workspace(uuid)}")
        stream = Fission::Utils::RemoteProcess::QueueStream.new

        event!(:info, :info => 'Starting package build!', :message_id => uuid)

        # @todo zoidberg embed future for tracking on supervised cleanup
        future = Zoidberg::Future.new do
          begin
            ephemeral.exec(command.join(' '), :stream => stream, :timeout => 3600)
          rescue => e
            error "Build failed (ID: #{uuid}): #{e.class} - #{e}"
            debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
            Fission::Utils::RemoteProcess::Result(-1, "Build failed (ID: #{uuid}): #{e.class} - #{e}")
          ensure
            stream.write :complete
          end
        end

        until((lines = stream.pop) == :complete)
          lines.split("\n").each do |line|
            line = line.sub(/^\[.+?\]/, '').strip
            next if line.empty?
            debug "Log line: #{line}"
            event!(:info, :info => line, :message_id => uuid)
          end
        end

        result = future.value

        ephemeral.exec!("ls #{workspace(uuid, :packages)}").output.read.split("\n").each do |file|
          file_path = File.join(workspace(uuid, :packages), file.strip)
          remote_file = ephemeral.get_file(file_path)
          File.open(file_path, 'wb') do |local_file|
            if(remote_file.respond_to?(:readpartial))
              while(content = remote_file.readpartial(2048))
                local_file.write content
              end
            else
              local_file.write remote_file
            end
          end
        end

        remote_log_file = ephemeral.get_file(log_file_path)
        local_log_file = File.open(log_file_path, 'w') do |file|
          if(remote_log_file.respond_to?(:readpartial))
            while(line = remote_log_file.readpartial(2048))
              file.write line
            end
          else
            file.write remote_log_file
          end
        end

        ephemeral.terminate

        if(result && result.success?)
          event!(:info, :info => 'Package build completed!', :message_id => uuid)
          debug "Finished command: #{command.join(' ')}"
        else
          error "Package build failed: #{command.join(' ')}}"
          error "Package build failed - Exit status of `#{result.exit_code}`"
          error = Fission::Error::RemoteProcessFailed.new("Package build failed - Exit code: #{result.exit_code}")
          raise error
        end
      end

      # uuid:: unique id (message id)
      # thing:: bucket in workspace
      # Return path to workspace (creates if required)
      def workspace(uuid, thing=nil)
        base = working_directory(:message_id => uuid)
        path = File.join(base, uuid, thing.to_s)
        unless(File.directory?(path))
          FileUtils.mkdir_p(path)
        end
        path
      end

      # uuid:: unique id (message id)
      # repo_path:: Repo to fetch
      # Unpacks repository into `code` workspace
      def repository_copy(uuid, repo_path)
        code_path = workspace(uuid, :code)
        asset_store.unpack(asset_store.get(repo_path), code_path)
      end

      # Path to packager specific cookbooks for building that are
      # vendored with the library
      def fission_cookbook_path
        unless(@cookbook_path)
          @cookbook_path = File.expand_path(File.join(File.dirname(__FILE__), '../../vendor/cookbooks'))
        end
        @cookbook_path
      end

      # uuid:: unique id (message id)
      # Writes the configuration file for chef
      def write_solo_config(uuid)
        solo_path = File.join(workspace(uuid, :solos), "solo.rb")
        unless(File.exists?(solo_path))
          cache_path = workspace(uuid, :chef_cache)
          cookbook_path = cookbook_copy(uuid)
          File.open(solo_path, 'w') do |file|
            file.puts "log_location STDOUT"
            file.puts "file_cache_path '#{cache_path}'"
            file.puts "cookbook_path '#{cookbook_path}'"
          end
        end
        solo_path
      end

      # uuid:: unique id (message id)
      # Copies vendored cookbooks to local path for chef run. Returns
      # path of copy
      # NOTE: Cookbooks need to be copied to allow proper bind
      # NOTE: This will be updated soon so containers have set
      # readonly bind defined in base container so ephemerals will
      # automatically have it available.
      def cookbook_copy(uuid)
        local_path = workspace(uuid, :cookbooks)
        directory_copy(fission_cookbook_path, local_path)
        local_path
      end

      # Path to chef-solo
      def chef_exec_path
        config.fetch(:chef_solo_path, 'chef-solo')
      end

      # source:: source directory
      # target:: target directory
      # Streaming file copy. This is to allow extracting files from a
      # jar to the local FS without hitting weird encoding issues.
      def directory_copy(source, target)
        unless(File.directory?(target))
          FileUtils.mkdir_p(target)
        end
        Dir.new(source).each do |_path|
          next if _path == '.' || _path == '..'
          path = File.join(source, _path)
          if(File.directory?(path))
            directory_copy(path, File.join(target, _path))
          else
            new_path = File.join(target, _path)
            unless(File.directory?(File.dirname(new_path)))
              FileUtils.mkdir_p(File.dirname(new_path))
            end
            begin
              source_file = File.open(path, 'rb')
              File.open(new_path, 'wb') do |new_file|
                while(data = source_file.read(2048))
                  new_file.print data
                end
              end
            rescue => e
              error "Failed to copy file to local system: #{path} -> #{new_path}"
              debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
            end
          end
        end
        true
      end

      # payload:: Payload
      # Attempt to extract error message from chef-stacktrace if file
      # exists and error is findable
      def extract_chef_stacktrace(payload)
        uuid = payload[:message_id]
        path = File.join(workspace(uuid, :log), "#{uuid}.log")
        error_msg = 'Failed to extract error information!'
        if(File.exists?(path))
          debug "Found chef log file for error extraction (#{path})"
          content = File.readlines(path)
          start = content.index{|line| line.include?('ERROR')}
          if(start)
            if(content[start.next].include?('--- Begin'))
              stop = content.index{|line| line.include?('--- End')}
              error_msg = content.slice(start.next, stop - start.next).join("\n")
            else
              errors = content.find_all{|line| line.include?('ERROR')}
              debug "Found ERROR lines from log: #{errors.inspect}"
              error_msg = errors.last
            end
          end
        end
        debug "Extracted error information: #{error_msg}"
        error_msg
      end

    end
  end
end

Fission.register(:package_builder, :builder, Fission::PackageBuilder::Builder)
