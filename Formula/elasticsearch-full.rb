class ElasticsearchFull < Formula
  desc "Distributed search & analytics engine"
  homepage "https://www.elastic.co/products/elasticsearch"
  url "file:///path/here"
  version "8.0.0"
  sha256 "ac1949836c64d4d1b1b9273400d5fd3a91bb6964ded67d2947e93324fad94028"
  conflicts_with "elasticsearch"

  bottle :unneeded

  resource "open3" do
    url "https://rubygems.org/downloads/open3-0.1.1.gem"
    sha256 "59a2c2cfe7a90ae3a35180e6acb2499699a9241bd2fedf18e46e3e8756bbe878"
  end

  def cluster_name
    "elasticsearch_#{ENV["USER"]}"
  end

  def install
    # Install everything else into package directory
    libexec.install "bin", "config", "jdk.app", "lib", "modules"

    inreplace libexec/"bin/elasticsearch-env",
              "if [ -z \"$ES_PATH_CONF\" ]; then ES_PATH_CONF=\"$ES_HOME\"/config; fi",
              "if [ -z \"$ES_PATH_CONF\" ]; then ES_PATH_CONF=\"#{etc}/elasticsearch\"; fi"

    # Set up Elasticsearch for local development:
    inreplace "#{libexec}/config/elasticsearch.yml" do |s|
      # 1. Give the cluster a unique name
      s.gsub!(/#\s*cluster\.name\: .*/, "cluster.name: #{cluster_name}")

      # 2. Configure paths
      s.sub!(%r{#\s*path\.data: /path/to.+$}, "path.data: #{var}/lib/elasticsearch/")
      s.sub!(%r{#\s*path\.logs: /path/to.+$}, "path.logs: #{var}/log/elasticsearch/")
    end

    with_env(ES_MAIN_CLASS: "org.elasticsearch.xpack.security.cli.ConfigInitialNode", ES_ADDITIONAL_SOURCES: "x-pack-env;x-pack-security-env", ES_ADDITIONAL_CLASSPATH_DIRECTORIES: "lib/tools/security-cli") do
      output, status = Open3.capture2(libexec/"bin/elasticsearch-cli", :stdin_data => "")
    end
    if status.success?
      with_env(ES_MAIN_CLASS: "org.elasticsearch.xpack.security.enrollment.tool.AutoConfigGenerateElasticPasswordHash", ES_ADDITIONAL_SOURCES: "x-pack-env;x-pack-security-env", ES_ADDITIONAL_CLASSPATH_DIRECTORIES: "lib/tools/security-cli") do
        @password, @autoconfiguration_status = Open3.capture2(libexec/"bin/elasticsearch-cli", :stdin_data => "")
      end
      if password_status.success?
        @autoconfiguration_output = <<~EOS
            ##########         Security autoconfiguration information         ############
            #                                                                            #
            # Authentication and Authorization are enabled.                              #
            # TLS for the transport and the http layers is enabled and configured.       #
            #                                                                            #
            # The password of the elastic superuser will be set to: ${INITIAL_PASSWORD} #
            # upon starting elasticsearch for the first time                             #
            #                                                                            #
            ##############################################################################
            EOS
      end
    else
      if status.80?
        @autoconfiguration_output = <<~EOS
            ##########         Security autoconfiguration information         ############
            #                                                                            #
            # Security features appear to be already configured.                         #
            #                                                                            #
            ##############################################################################
            EOS
      else
        @autoconfiguration_output = <<~EOS
            ##########         Security autoconfiguration information         ############
            #                                                                            #
            # Failed to auto-configure security features.                                #
            # Authentication and Authorization are enabled.                              #
            # You can use elasticsearch-reset-elastic-password to set a password         #
            # for the elastic user.                                                      #
            #                                                                            #
            ##############################################################################
            EOS
      end
    end

    inreplace "#{libexec}/config/jvm.options", %r{logs/gc.log}, "#{var}/log/elasticsearch/gc.log"

    # Move config files into etc
    (etc/"elasticsearch").install Dir[libexec/"config/*"]
    (libexec/"config").rmtree

    Dir.foreach(libexec/"bin") do |f|
      next if f == "." || f == ".." || !File.extname(f).empty?

      bin.install libexec/"bin"/f
    end
    bin.env_script_all_files(libexec/"bin", {})

    system "codesign", "-f", "-s", "-", "#{libexec}/modules/x-pack-ml/platform/darwin-x86_64/controller.app", "--deep"
    system "find", "#{libexec}/jdk.app/Contents/Home/bin", "-type", "f", "-exec", "codesign", "-f", "-s", "-", "{}", ";"
  end

  def post_install
    # Make sure runtime directories exist
    (var/"lib/elasticsearch/#{cluster_name}").mkpath
    (var/"log/elasticsearch").mkpath
    ln_s etc/"elasticsearch", libexec/"config"
    (var/"elasticsearch/plugins").mkpath
    ln_s var/"elasticsearch/plugins", libexec/"plugins"
  end

  def caveats
    s = <<~EOS
      Data:    #{var}/lib/elasticsearch/#{cluster_name}/
      Logs:    #{var}/log/elasticsearch/#{cluster_name}.log
      Plugins: #{var}/elasticsearch/plugins/
      Config:  #{etc}/elasticsearch/
    EOS
    s += @autoconfiguration_output

    s
  end

  plist_options :manual => "elasticsearch"

  def plist
    <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
        <dict>
          <key>KeepAlive</key>
          <false/>
          <key>Label</key>
          <string>#{plist_name}</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{opt_bin}/elasticsearch</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
          </dict>
          <key>RunAtLoad</key>
          <true/>
          <key>WorkingDirectory</key>
          <string>#{var}</string>
          <key>StandardErrorPath</key>
          <string>#{var}/log/elasticsearch.log</string>
          <key>StandardOutPath</key>
          <string>#{var}/log/elasticsearch.log</string>
        </dict>
      </plist>
    EOS
  end

  test do
    require "socket"

    server = TCPServer.new(0)
    port = server.addr[1]
    server.close

    mkdir testpath/"config"
    cp etc/"elasticsearch/jvm.options", testpath/"config"
    cp etc/"elasticsearch/log4j2.properties", testpath/"config"
    cp etc/"elasticsearch/elasticsearch.yml", testpath/"config"

    ENV["ES_PATH_CONF"] = testpath/"config"

    system "#{bin}/elasticsearch-plugin", "list"

    pid = testpath/"pid"
    begin
      system "#{bin}/elasticsearch", "-d", "-p", pid, "-Epath.data=#{testpath}/data", "-Epath.logs=#{testpath}/logs", "-Enode.name=test-cli", "-Ehttp.port=#{port}"
      sleep 30
      system "curl", "-XGET", "localhost:#{port}/"
      output = shell_output("curl -s -XGET localhost:#{port}/_cat/nodes")
      assert_match "test-cli", output
    ensure
      Process.kill(9, pid.read.to_i)
    end

    server = TCPServer.new(0)
    port = server.addr[1]
    server.close

    rm testpath/"config/elasticsearch.yml"
    (testpath/"config/elasticsearch.yml").write <<~EOS
      path.data: #{testpath}/data
      path.logs: #{testpath}/logs
      node.name: test-es-path-conf
      http.port: #{port}
    EOS

    pid = testpath/"pid"
    begin
      system "#{bin}/elasticsearch", "-d", "-p", pid
      sleep 30
      system "curl", "-XGET", "localhost:#{port}/"
      output = shell_output("curl -s -XGET localhost:#{port}/_cat/nodes")
      assert_match "test-es-path-conf", output
    ensure
      Process.kill(9, pid.read.to_i)
    end

    if @autoconfiguration_status.success?

      server = TCPServer.new(0)
      port = server.addr[1]
      server.close

      rm testpath/"config"
      mkdir testpath/"config"
      cp etc/"elasticsearch/jvm.options", testpath/"config"
      cp etc/"elasticsearch/log4j2.properties", testpath/"config"
      cp etc/"elasticsearch/elasticsearch.yml", testpath/"config"
      cp etc/"elasticsearch/elasticsearch.keystore", testpath/"config"
      cp -r etc/"elasticsearch/tls_auto_config_initial_node_*", testpath/"config"

      ENV["ES_PATH_CONF"] = testpath/"config"

      pid = testpath/"pid"
      begin
        system "#{bin}/elasticsearch", "-d", "-p", pid, "-Epath.data=#{testpath}/data", "-Epath.logs=#{testpath}/logs", "-Enode.name=test-security-autoconfiguration", "-Ehttp.port=#{port}"
       sleep 30
        system "curl", "-XGET", "https://localhost:#{port}/", "-uelastic"+@password
        output = shell_output("curl -s -XGET https://localhost:#{port}/_cat/nodes")
        assert_match "test-security-autoconfiguration", output
      ensure
        Process.kill(9, pid.read.to_i)
      end

  end
end
