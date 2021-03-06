module Morph
  # More low-level API for running scrapers. Does not do much of the magic
  # and is less opinionated than the higher-level API in Morph::Runner
  class DockerRunner
    ALL_CONFIG_FILENAMES = [
      'Procfile',
      'Gemfile', 'Gemfile.lock',
      'requirements.txt', 'runtime.txt',
      'composer.json', 'composer.lock',
      'app.psgi', 'cpanfile'
    ]
    BUILDSTEP_IMAGE = 'openaustralia/buildstep'

    def self.compile_and_run(repo_path, env_variables, container_name,
                             container_labels, files)
      wrapper = Multiblock.wrapper
      yield(wrapper)

      i = Morph::DockerUtils.get_or_pull_image(BUILDSTEP_IMAGE) do |c|
        wrapper.call(:log, :internalout, c)
      end
      # Insert the configuration part of the application code into the container
      i2 = Dir.mktmpdir('morph') do |dest|
        copy_config_to_directory(repo_path, dest, true)
        wrapper.call(:log, :internalout,
                     "Injecting configuration and compiling...\n")
        inject_files(i, dest)
      end
      i3 = compile(i2) do |c|
        wrapper.call(:log, :internalout, c)
      end
      # If something went wrong during the compile and it couldn't finish
      if i3.nil?
        # TODO: Return the status for a compile error
        return Morph::RunResult.new(255, {}, {})
      end

      # Insert the actual code (and database) into the container
      i4 = Dir.mktmpdir('morph') do |dest|
        copy_config_to_directory(repo_path, dest, false)
        wrapper.call(:log, :internalout,
                     "Injecting scraper and running...\n")
        inject_files2(i3, dest)
      end

      time_file = '/app/time.output'
      command = Morph::TimeCommand.command('/start scraper', time_file)

      # Make the paths absolute paths for the container
      files = files.map { |f| File.join('/app', f)}
      # TODO: Also copy back time output file and the sqlite journal file
      # The sqlite journal file won't be present most of the time
      status_code, data = run(
        i4.id, command, env_variables, container_name,
        container_labels, files + [time_file]) do |on|
        on.log { |s, c| wrapper.call(:log, s, c) }
        on.ip_address { |ip| wrapper.call(:ip_address, ip) }
      end

      time_data = data.delete(time_file)
      time_params = Morph::TimeCommand.params_from_string(time_data) if time_data

      # Remove /app from the beginning of all paths in data
      data_with_stripped_paths = {}
      data.each do |path, content|
        stripped_path =
          Pathname.new(path).relative_path_from(Pathname.new('/app')).to_s
        data_with_stripped_paths[stripped_path] = content
      end

      # There's a potential race condition here where we are trying to delete
      # something that might be used elsewhere. Do the most crude thing and
      # just ignore any errors that deleting might throw up.
      begin
        i4.delete('noprune' => 1)
      rescue Docker::Error::ConfictError
        # TODO: When docker-api gem gets updated Docker::Error::ConfictError
        # will be changed to Docker::Error::ConflictError
      end

      Morph::RunResult.new(status_code, data_with_stripped_paths, time_params)
    end

    # If copy_config is true copies the config file across
    # Otherwise copies the other files across
    def self.copy_config_to_directory(source, dest, copy_config)
      Dir.entries(source).each do |entry|
        if entry != '.' && entry != '..'
          unless copy_config ^ ALL_CONFIG_FILENAMES.include?(entry)
            FileUtils.copy_entry(File.join(source, entry),
                                 File.join(dest, entry))
          end
        end
      end
    end

    def self.update_docker_image!
      Morph::DockerUtils.pull_docker_image(BUILDSTEP_IMAGE)
    end

    private

    # files - paths to files to return at the end of the run
    def self.run(image_name, command, env_variables, container_name,
                 container_labels, files)
      wrapper = Multiblock.wrapper
      yield(wrapper)

      c = run_no_cleanup(image_name, command,
                         env_variables, container_name, container_labels) do |on|
        on.log { |s, c| wrapper.call(:log, s, c) }
        on.ip_address { |ip| wrapper.call(:ip_address, ip) }
      end

      status_code = c.json['State']['ExitCode']
      # Wait until container has definitely stopped
      c.wait

      # Grab the resulting files
      data = Morph::DockerUtils.copy_files(c, files)

      # Clean up after ourselves
      c.delete

      [status_code, data]
    end

    def self.run_no_cleanup(image_name, command, env_variables, container_name,
                            container_labels)
      wrapper = Multiblock.wrapper
      yield(wrapper)

      # Open up a special interactive connection to Docker
      # TODO: Cache connection
      conn_interactive = Docker::Connection.new(
        Docker.url,
        {chunk_size: 1, read_timeout: 4.hours}.merge(Docker.env_options))

      container_options = {
        'Cmd' => ['/bin/bash', '-l', '-c', command],
        # TODO: We can just get rid of the line below, right?
        # (because it's the default)
        'User' => 'root',
        'Image' => image_name,
        # See explanation in https://github.com/openaustralia/morph/issues/242
        'CpuShares' => 307,
        # Memory limit (in bytes)
        # On a 1G machine we're allowing a max of 10 containers to run at
        # a time. So, 100M
        'Memory' => 100 * 1024 * 1024,
        'Env' => env_variables.map { |k, v| "#{k}=#{v}" },
        'Labels' => container_labels
      }

      # This will fail if there is another container with the same name
      begin
        c = Docker::Container.create(container_options, conn_interactive)
      rescue Excon::Errors::SocketError => e
        text = "Could not connect to Docker server: #{e}"
        wrapper.call(:log, :internalerr, "morph.io internal error: #{text}\n")
        wrapper.call(:log, :internalerr, "Requeueing...\n")
        raise text
      rescue Docker::Error::NotFoundError => e
        text = "Could not find docker image #{image_name}"
        wrapper.call(:log, :internalerr, "morph.io internal error: #{text}\n")
        wrapper.call(:log, :internalerr, "Requeueing...\n")
        raise text
      end

      begin
        c.start
        # puts 'Running docker container...'
        # Let parent know about ip address of running container
        wrapper.call(:ip_address, c.json['NetworkSettings']['IPAddress'])
        c.attach(logs: true) do |s, c|
          # We're going to assume (somewhat rashly, I might add) that the
          # console output from the scraper is always encoded as UTF-8.
          c.force_encoding('UTF-8')
          c.scrub!
          # There are times when multiple lines are returned and this does
          # not always happen consistently. So, for simplicity and consistency
          # we will split multiple lines up
          while i = c.index("\n")
            wrapper.call(:log, s, c[0..i])
            c = c[i+1..-1]
          end
          # Anything left over
          wrapper.call(:log, s, c) if c.length > 0
        end
        # puts 'Docker container finished...'
      rescue Exception => e
        wrapper.call(:log,  :internalerr, "morph.io internal error: #{e}\n")
        wrapper.call(:log, :internalerr,
                     "Stopping current container and requeueing\n")
        c.kill
        raise e
      end
      c
    end

    def self.docker_build_command(image, commands, dir)
      # Leave the files in dir untouched
      Dir.mktmpdir('morph') do |dir2|
        Morph::DockerUtils.copy_directory_contents(dir, dir2)
        File.open(File.join(dir2, 'Dockerfile'), 'w') do |f|
          f.write dockerfile_contents_from_commands(image, commands)
        end

        Morph::DockerUtils.fix_modification_times(dir2)
        Morph::DockerUtils.docker_build_from_dir(
          dir2, read_timeout: 4.hours) do |c|
          yield c
        end
      end
    end

    def self.dockerfile_contents_from_commands(image, commands)
      commands = [commands] unless commands.is_a?(Array)
      "from #{image.id}\n" + commands.map { |c| c + "\n" }.join
    end

    # Inject all files in the given directory into the /app directory in the
    # image and return a new image
    def self.inject_files(image, dest)
      Dir.mktmpdir('morph') do |dir|
        FileUtils.mkdir(File.join(dir, 'app'))
        Morph::DockerUtils.copy_directory_contents(dest, File.join(dir, 'app'))
        docker_build_command(image, ['ADD app /app'], dir) do |c|
          # Note that we're not sending the output of this to the console
          # because it is relatively short running and is otherwise confusing
        end
      end
    end

    def self.inject_files2(image, dest)
      Dir.mktmpdir('morph') do |dir|
        Morph::DockerUtils.copy_directory_contents(dest, File.join(dir, 'app'))
        docker_build_command(
          image,
          ['ADD app /app', 'RUN chown -R scraper:scraper /app'],
          dir) do |c|
          # Note that we're not sending the output of this to the console
          # because it is relatively short running and is otherwise confusing
        end
      end
    end

    # And build
    # TODO: Set memory and cpu limits during compile
    def self.compile(image)
      Dir.mktmpdir('morph') do |dir|
        docker_build_command(
          image,
          ['ENV CURL_TIMEOUT 180', 'RUN /build/builder'],
          dir) do |c|
          # We don't want to show the standard docker build output
          unless c =~ /^Step \d+ :/ || c =~ /^ ---> / ||
                 c =~ /^Removing intermediate container / ||
                 c =~ /^Successfully built /
            yield c
          end
        end
      end
    end
  end
end
