module Beaker
  class Docker < Beaker::Hypervisor

    # Docker hypvervisor initializtion
    # Env variables supported:
    # DOCKER_REGISTRY: Docker registry URL
    # DOCKER_HOST: Remote docker host
    # DOCKER_BUILDARGS: Docker buildargs map
    # @param [Host, Array<Host>, String, Symbol] hosts    One or more hosts to act upon,
    #                            or a role (String or Symbol) that identifies one or more hosts.
    # @param [Hash{Symbol=>String}] options Options to pass on to the hypervisor
    def initialize(hosts, options)
      require 'docker'
      @options = options
      @logger = options[:logger] || Beaker::Logger.new
      @hosts = hosts

      # increase the http timeouts as provisioning images can be slow
      default_docker_options = { :write_timeout => 300, :read_timeout => 300 }.merge(::Docker.options || {})
      # Merge docker options from the entry in hosts file
      ::Docker.options = default_docker_options.merge(@options[:docker_options] || {})
      # assert that the docker-api gem can talk to your docker
      # enpoint.  Will raise if there is a version mismatch
      begin
        ::Docker.validate_version!
      rescue Excon::Errors::SocketError => e
        raise "Docker instance not connectable.\nError was: #{e}\nCheck your DOCKER_HOST variable has been set\nIf you are on OSX or Windows, you might not have Docker Machine setup correctly: https://docs.docker.com/machine/\n"
      end

      # Pass on all the logging from docker-api to the beaker logger instance
      ::Docker.logger = @logger

      # Find out what kind of remote instance we are talking against
      if ::Docker.version['Version'] =~ /swarm/
        @docker_type = 'swarm'
        unless ENV['DOCKER_REGISTRY']
          raise "Using Swarm with beaker requires a private registry. Please setup the private registry and set the 'DOCKER_REGISTRY' env var"
        else
          @registry = ENV['DOCKER_REGISTRY']
        end
      else
        @docker_type = 'docker'
      end

    end

    def install_and_run_ssh(host)
      host['dockerfile'] || host['use_image_entry_point']
    end

    def get_container_opts(host, image_name)
      container_opts = {}
      if host['dockerfile']
        container_opts['ExposedPorts'] = {'22/tcp' => {} }
      end

      container_opts.merge! ( {
        'Image' => image_name,
        'Hostname' => host.name,
        'HostConfig' => {
          'PortBindings' => {
            '22/tcp' => [{ 'HostPort' => rand.to_s[2..5], 'HostIp' => '0.0.0.0'}]
          },
          'PublishAllPorts' => true,
          'Privileged' => true,
          'RestartPolicy' => {
            'Name' => 'always'
          }
        }
      } )
    end

    def get_container_image(host)
      @logger.debug("Creating image")

      if host['use_image_as_is']
        return ::Docker::Image.create('fromImage' => host['image'])
      end

      dockerfile = host['dockerfile']
      if dockerfile
        # assume that the dockerfile is in the repo and tests are running
        # from the root of the repo; maybe add support for external Dockerfiles
        # with external build dependencies later.
        if File.exist?(dockerfile)
          dir = File.expand_path(dockerfile).chomp(dockerfile)
          return ::Docker::Image.build_from_dir(
            dir,
            { 'dockerfile' => dockerfile,
              :rm => true,
              :buildargs => buildargs_for(host)
            }
          )
        else
          raise "Unable to find dockerfile at #{dockerfile}"
        end
      elsif host['use_image_entry_point']
        df = <<-DF
          FROM #{host['image']}
          EXPOSE 22
        DF

        cmd = host['docker_cmd']
        df += cmd if cmd
        return ::Docker::Image.build(df, { rm: true, buildargs: buildargs_for(host) })
      end

      return ::Docker::Image.build(dockerfile_for(host),
                  { rm: true, buildargs: buildargs_for(host) })
    end

    def provision
      @logger.notify "Provisioning docker"

      @hosts.each do |host|
        @logger.notify "provisioning #{host.name}"


        image = get_container_image(host)

        if host['tag']
          image.tag({:repo => host['tag']})
        end

        if @docker_type == 'swarm'
          image_name = "#{@registry}/beaker/#{image.id}"
          ret = ::Docker::Image.search(:term => image_name)
          if ret.first.nil?
            @logger.debug("Image does not exist on registry. Pushing.")
            image.tag({:repo => image_name, :force => true})
            image.push
          end
        else
          image_name = image.id
        end

        container_opts = get_container_opts(host, image_name)
        if host['dockeropts'] || @options[:dockeropts]
          dockeropts = host['dockeropts'] ? host['dockeropts'] : @options[:dockeropts]
          dockeropts.each do |k,v|
            container_opts[k] = v
          end
        end

        container = find_container(host)

        # Provisioning - Only provision if the host's container can't be found
        # via its name or ID
        if container.nil?
          unless host['mount_folders'].nil?
            container_opts['HostConfig'] ||= {}
            container_opts['HostConfig']['Binds'] = host['mount_folders'].values.map do |mount|
              host_path = File.expand_path(mount['host_path'])
              # When using docker_toolbox and getting a "(Driveletter):/" path, convert windows path to VM mount
              if ENV['DOCKER_TOOLBOX_INSTALL_PATH'] && host_path =~ /^.\:\//
                host_path = "/" + host_path.gsub(/^.\:/, host_path[/^(.)/].downcase)
              end
              a = [ host_path, mount['container_path'] ]
              a << mount['opts'] if mount.has_key?('opts')
              a.join(':')
            end
          end

          if host['docker_env']
            container_opts['Env'] = host['docker_env']
          end

          if host['docker_cap_add']
            container_opts['HostConfig']['CapAdd'] = host['docker_cap_add']
          end

          if host['docker_container_name']
            container_opts['name'] = host['docker_container_name']
          end

          @logger.debug("Creating container from image #{image_name}")
          container = ::Docker::Container.create(container_opts)
        else
          host['use_existing_container'] = true
        end

        if container.nil?
          raise RuntimeError, 'Cannot continue because no existing container ' +
                              'could be found and provisioning is disabled.'
        end

        fix_ssh(container) if @options[:provision] == false

        @logger.debug("Starting container #{container.id}")
        container.start

        if install_and_run_ssh(host)
          @logger.notify("Installing ssh components and starting ssh daemon in #{host} container")
          install_ssh_components(container, host)
          # run fixssh to configure and start the ssh service
          fix_ssh(container, host)
        end
        # Find out where the ssh port is from the container
        # When running on swarm DOCKER_HOST points to the swarm manager so we have to get the
        # IP of the swarm slave via the container data
        # When we are talking to a normal docker instance DOCKER_HOST can point to a remote docker instance.

        # Talking against a remote docker host which is a normal docker host
        if @docker_type == 'docker' && ENV['DOCKER_HOST']
          ip = URI.parse(ENV['DOCKER_HOST']).host
        else
          # Swarm or local docker host
          if in_container?
            ip = container.json["NetworkSettings"]["Gateway"]
          else
            ip = container.json["NetworkSettings"]["Ports"]["22/tcp"][0]["HostIp"]
          end
        end

        @logger.info("Using docker server at #{ip}")
        port = container.json["NetworkSettings"]["Ports"]["22/tcp"][0]["HostPort"]

        forward_ssh_agent = @options[:forward_ssh_agent] || false

        # Update host metadata
        host['ip']  = ip
        host['port'] = port
        host['ssh']  = {
          :password => root_password,
          :port => port,
          :forward_agent => forward_ssh_agent,
        }

        @logger.debug("node available as  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@#{ip} -p #{port}")
        host['docker_container_id'] = container.id
        host['docker_image_id'] = image.id
        host['vm_ip'] = container.json["NetworkSettings"]["IPAddress"].to_s

      end

      hack_etc_hosts @hosts, @options

    end

    # This sideloads sshd after a container starts
    def install_ssh_components(container, host)
      case host['platform']
      when /ubuntu/, /debian/
        container.exec(%w(apt-get update))
        container.exec(%w(apt-get install -y openssh-server openssh-client))
      when /cumulus/
        container.exec(%w(apt-get update))
        container.exec(%w(apt-get install -y openssh-server openssh-client))
      when /fedora-(2[2-9])/
        container.exec(%w(dnf clean all))
        container.exec(%w(dnf install -y sudo openssh-server openssh-clients))
        container.exec(%w(ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key))
        container.exec(%w(ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key))
      when /^el-/, /centos/, /fedora/, /redhat/, /eos/
        container.exec(%w(yum clean all))
        container.exec(%w(yum install -y sudo openssh-server openssh-clients))
        container.exec(%w(ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key))
        container.exec(%w(ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key))
      when /opensuse/, /sles/
        container.exec(%w(zypper -n in openssh))
        container.exec(%w(ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key))
        container.exec(%w(ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key))
        container.exec(%w(sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config))
      when /archlinux/
        container.exec(%w(pacman --noconfirm -Sy archlinux-keyring))
        container.exec(%w(pacman --noconfirm -Syu))
        container.exec(%w(pacman -S --noconfirm openssh))
        container.exec(%w(ssh-keygen -A))
        container.exec(%w(sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config))
        container.exec(%w(systemctl enable sshd))
      when /alpine/
        container.exec(%w(apk add --update openssh))
        container.exec(%w(ssh-keygen -A))
      else
        # TODO add more platform steps here
        raise "platform #{host['platform']} not yet supported on docker"
      end

      # Make sshd directory, set root password
      container.exec(%w(mkdir -p /var/run/sshd))
      container.exec(['/bin/sh', '-c', "echo root:#{root_password} | chpasswd"])
    end

    def cleanup
      @logger.notify "Cleaning up docker"
      @hosts.each do |host|
        # leave the container running if docker_preserve_container is set
        # setting docker_preserve_container also implies docker_preserve_image
        # is set, since you can't delete an image that's the base of a running
        # container
        unless host['docker_preserve_container']
          container = find_container(host)
          if container
            @logger.debug("stop container #{container.id}")
            begin
              container.kill
              sleep 2 # avoid a race condition where the root FS can't unmount
            rescue Excon::Errors::ClientError => e
              @logger.warn("stop of container #{container.id} failed: #{e.response.body}")
            end
            @logger.debug("delete container #{container.id}")
            begin
              container.delete
            rescue Excon::Errors::ClientError => e
              @logger.warn("deletion of container #{container.id} failed: #{e.response.body}")
            end
          end

          # Do not remove the image if docker_preserve_image is set to true, otherwise remove it
          unless host['docker_preserve_image']
            image_id = host['docker_image_id']

            if image_id
              @logger.debug("deleting image #{image_id}")
              begin
                ::Docker::Image.remove(image_id)
              rescue Excon::Errors::ClientError => e
                @logger.warn("deletion of image #{image_id} failed: #{e.response.body}")
              rescue ::Docker::Error::DockerError => e
                @logger.warn("deletion of image #{image_id} caused internal Docker error: #{e.message}")
              end
            else
              @logger.warn("Intended to delete the host's docker image, but host['docker_image_id'] was not set")
            end
          end
        end
      end
    end

    private

    def root_password
      'root'
    end

    def buildargs_for(host)
      docker_buildargs = {}
      docker_buildargs_env = ENV['DOCKER_BUILDARGS']
      if docker_buildargs_env != nil
        docker_buildargs_env.split(/ +|\t+/).each do |arg|
          key,value=arg.split(/=/)
          if key
            docker_buildargs[key]=value
          else
            @logger.warn("DOCKER_BUILDARGS environment variable appears invalid, no key found for value #{value}" )
          end
        end
      end
      if docker_buildargs.empty?
        buildargs = host['docker_buildargs'] || {}
      else
        buildargs = docker_buildargs
      end
      @logger.debug("Docker build buildargs: #{buildargs}")
      JSON.generate(buildargs)
    end

    def dockerfile_for(host)
      # specify base image
      dockerfile = <<-EOF
        FROM #{host['image']}
        ENV container docker
      EOF

      # additional options to specify to the sshd
      # may vary by platform
      sshd_options = ''

      # add platform-specific actions
      service_name = "sshd"
      case host['platform']
      when /ubuntu/, /debian/
        service_name = "ssh"
        dockerfile += <<-EOF
          RUN apt-get update
          RUN apt-get install -y openssh-server openssh-client #{Beaker::HostPrebuiltSteps::DEBIAN_PACKAGES.join(' ')}
        EOF
        when  /cumulus/
          dockerfile += <<-EOF
          RUN apt-get update
          RUN apt-get install -y openssh-server openssh-client #{Beaker::HostPrebuiltSteps::CUMULUS_PACKAGES.join(' ')}
        EOF
      when /fedora-(2[2-9])/
        dockerfile += <<-EOF
          RUN dnf clean all
          RUN dnf install -y sudo openssh-server openssh-clients #{Beaker::HostPrebuiltSteps::UNIX_PACKAGES.join(' ')}
          RUN ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key
          RUN ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key
        EOF
      when /^el-/, /centos/, /fedora/, /redhat/, /eos/
        dockerfile += <<-EOF
          RUN yum clean all
          RUN yum install -y sudo openssh-server openssh-clients #{Beaker::HostPrebuiltSteps::UNIX_PACKAGES.join(' ')}
          RUN ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key
          RUN ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key
        EOF
      when /opensuse/, /sles/
        dockerfile += <<-EOF
          RUN zypper -n in openssh #{Beaker::HostPrebuiltSteps::SLES_PACKAGES.join(' ')}
          RUN ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key
          RUN ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key
          RUN sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        EOF
      when /archlinux/
        dockerfile += <<-EOF
          RUN pacman --noconfirm -Sy archlinux-keyring
          RUN pacman --noconfirm -Syu
          RUN pacman -S --noconfirm openssh #{Beaker::HostPrebuiltSteps::ARCHLINUX_PACKAGES.join(' ')}
          RUN ssh-keygen -A
          RUN sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
          RUN systemctl enable sshd
        EOF
      else
        # TODO add more platform steps here
        raise "platform #{host['platform']} not yet supported on docker"
      end

      # Make sshd directory, set root password
      dockerfile += <<-EOF
        RUN mkdir -p /var/run/sshd
        RUN echo root:#{root_password} | chpasswd
      EOF

      # Configure sshd service to allowroot login using password
      # Also, disable reverse DNS lookups to prevent every. single. ssh
      # operation taking 30 seconds while the lookup times out.
      dockerfile += <<-EOF
        RUN sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
        RUN sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        RUN sed -ri 's/^#?UseDNS .*/UseDNS no/' /etc/ssh/sshd_config
      EOF


      # Any extra commands specified for the host
      dockerfile += (host['docker_image_commands'] || []).map { |command|
        "RUN #{command}\n"
      }.join('')

      # Override image entrypoint
      if host['docker_image_entrypoint']
        dockerfile += "ENTRYPOINT #{host['docker_image_entrypoint']}\n"
      end

      # How to start a sshd on port 22.  May be an init for more supervision
      # Ensure that the ssh server can be restarted (done from set_env) and container keeps running
      cmd = host['docker_cmd'] || ["sh","-c","service #{service_name} start ; tail -f /dev/null"]
      dockerfile += <<-EOF
        EXPOSE 22
        CMD #{cmd}
      EOF

    # end

      @logger.debug("Dockerfile is #{dockerfile}")
      return dockerfile
    end

    # a puppet run may have changed the ssh config which would
    # keep us out of the container.  This is a best effort to fix it.
    # Optionally pass in a host object to to determine which ssh
    # restart command we should try.
    def fix_ssh(container, host=nil)
      @logger.debug("Fixing ssh on container #{container.id}")
      container.exec(['sed','-ri',
                      's/^#?PermitRootLogin .*/PermitRootLogin yes/',
                      '/etc/ssh/sshd_config'])
      container.exec(['sed','-ri',
                      's/^#?PasswordAuthentication .*/PasswordAuthentication yes/',
                      '/etc/ssh/sshd_config'])
      container.exec(['sed','-ri',
                      's/^#?UseDNS .*/UseDNS no/',
                      '/etc/ssh/sshd_config'])
      # Make sure users with a bunch of SSH keys loaded in their keyring can
      # still run tests
      container.exec(['sed','-ri',
                     's/^#?MaxAuthTries.*/MaxAuthTries 1000/',
                     '/etc/ssh/sshd_config'])

      if host
        if host['platform'] =~ /alpine/
          container.exec(%w(/usr/sbin/sshd))
        else
          container.exec(%w(service ssh restart))
        end
      end
    end


    # return the existing container if we're not provisioning
    # and docker_container_name is set
    def find_container(host)
      id = host['docker_container_id']
      name = host['docker_container_name']
      return unless id || name

      containers = ::Docker::Container.all

      if id
        @logger.debug("Looking for an existing container with ID #{id}")
        container = containers.select { |c| c.id == id }.first
      end

      if name && container.nil?
        @logger.debug("Looking for an existing container with name #{name}")
        container = containers.select do |c|
          c.info['Names'].include? "/#{name}"
        end.first
      end

      return container unless container.nil?
      @logger.debug("Existing container not found")
      return nil
    end

    # return true if we are inside a docker container
    def in_container?
      return File.file?('/.dockerenv')
    end

  end
end
