# Requirements to build:
#   ant
#   cpio
#   wget
#
JRUBY_VERSION=1.6.5
ELASTICSEARCH_VERSION=0.18.6
VERSION=$(shell ruby -r./lib/logstash/version -e 'puts LOGSTASH_VERSION')

JRUBY_CMD=build/jruby/jruby-$(JRUBY_VERSION)/bin/jruby
WITH_JRUBY=bash $(JRUBY_CMD) --1.9 -S
JRUBY_URL=http://repository.codehaus.org/org/jruby/jruby-complete/$(JRUBY_VERSION)
JRUBY=vendor/jar/jruby-complete-$(JRUBY_VERSION).jar
JRUBYC=java -Djruby.compat.version=RUBY1_9 -jar $(PWD)/$(JRUBY) -S jrubyc
ELASTICSEARCH_URL=http://github.com/downloads/elasticsearch/elasticsearch
ELASTICSEARCH=vendor/jar/elasticsearch-$(ELASTICSEARCH_VERSION)
PLUGIN_FILES=$(shell git ls-files | egrep '^lib/logstash/(inputs|outputs|filters)/' | egrep -v '/base.rb$$')
GEM_HOME=build/gems
QUIET=@

# OS-specific options
TARCHECK=$(shell tar --help|grep wildcard|wc -l)
ifeq ($TARCHECK), 0)
TAR_OPTS=
else
TAR_OPTS=--wildcards
endif

default: jar

# Compile config grammar (ragel -> ruby)
.PHONY: compile-grammar
compile-grammar: lib/logstash/config/grammar.rb
lib/logstash/config/grammar.rb: lib/logstash/config/grammar.rl
	$(QUIET)$(MAKE) -C lib/logstash/config grammar.rb

.PHONY: clean
clean:
	@echo "=> Cleaning up"
	-$(QUIET)rm -rf .bundle
	-$(QUIET)rm -rf build
	-$(QUIET)rm -rf vendor

.PHONY: compile
compile: compile-grammar compile-runner | build/ruby

.PHONY: compile-runner
compile-runner: build/ruby/logstash/runner.class
build/ruby/logstash/runner.class: lib/logstash/runner.rb | build/ruby $(JRUBY)
	$(QUIET)(cd lib; JRUBY_OPTS=--1.9 $(JRUBYC) -t ../build/ruby logstash/runner.rb)

# TODO(sissel): Stop using cpio for this
.PHONY: copy-ruby-files
copy-ruby-files: | build/ruby
	@# Copy lib/ and test/ files to the root.
	$(QUIET)find ./lib -name '*.rb' | sed -e 's,^\./lib/,,' \
	| (cd lib; cpio -p --make-directories ../build/ruby)
	$(QUIET)find ./test -name '*.rb' | sed -e 's,^\./test/,,' \
	| (cd test; cpio -p --make-directories ../build/ruby)

vendor:
	$(QUIET)mkdir $@

vendor/jar: | vendor
	$(QUIET)mkdir $@

build-jruby: $(JRUBY)

$(JRUBY): build/jruby/jruby-$(JRUBY_VERSION)/lib/jruby-complete.jar | vendor/jar
	$(QUIET)cp $< $@

build/jruby: build
	$(QUIET)mkdir -p $@

$(JRUBY_CMD): build/jruby/jruby-$(JRUBY_VERSION)/lib/jruby-complete.jar
build/jruby/jruby-$(JRUBY_VERSION)/lib/jruby-complete.jar: build/jruby/jruby-$(JRUBY_VERSION)
	# Build jruby from source targeted at 1.9 - patch that, yo.
	$(QUIET)sed -i -e 's/jruby.default.ruby.version=.*/jruby.default.ruby.version=1.9/' $</default.build.properties
	$(QUIET)(cd $<; ant jar-jruby-complete)

build/jruby/jruby-$(JRUBY_VERSION): build/jruby/jruby-src-$(JRUBY_VERSION).tar.gz
	$(QUIET)tar -C build/jruby/ $(TAR_OPTS) -zxf $<

build/jruby/jruby-src-$(JRUBY_VERSION).tar.gz: | build/jruby
	@echo "=> Fetching jruby source"
	$(QUIET)wget -O $@ http://jruby.org.s3.amazonaws.com/downloads/$(JRUBY_VERSION)/jruby-src-$(JRUBY_VERSION).tar.gz

vendor/jar/elasticsearch-$(ELASTICSEARCH_VERSION).tar.gz: | vendor/jar
	@# --no-check-certificate is for github and wget not supporting wildcard
	@# certs sanely.
	@echo "=> Fetching elasticsearch"
	$(QUIET)wget --no-check-certificate \
		-O $@ $(ELASTICSEARCH_URL)/elasticsearch-$(ELASTICSEARCH_VERSION).tar.gz

.PHONY: vendor-elasticsearch
vendor-elasticsearch: $(ELASTICSEARCH)
$(ELASTICSEARCH): $(ELASTICSEARCH).tar.gz | vendor/jar
	@echo "=> Pulling the jars out of $<"
	$(QUIET)tar -C $(shell dirname $@) -xf $< $(TAR_OPTS) --exclude '*sigar*' \
		'elasticsearch-$(ELASTICSEARCH_VERSION)/lib/*.jar'

# Always run vendor/bundle
.PHONY: fix-bundler
fix-bundler:
	-$(QUIET)rm -rf .bundle

.PHONY: vendor-gems
vendor-gems: | vendor/bundle

$(GEM_HOME)/bin/bundle: | $(JRUBY_CMD)
	@echo "=> Installing bundler ($@)"
	$(QUIET)GEM_HOME=$(GEM_HOME) $(WITH_JRUBY) gem install bundler

.PHONY: vendor/bundle
vendor/bundle: | $(GEM_HOME)/bin/bundle fix-bundler
	@echo "=> Installing gems to $@..."
	$(QUIET)GEM_HOME=$(GEM_HOME) bash $(JRUBY_CMD) --1.9 $(GEM_HOME)/bin/bundle install --deployment

gem: logstash-$(VERSION).gem

logstash-$(VERSION).gem: compile
	$(QUIET)$(WITH_JRUBY) gem build logstash.gemspec

build:
	-$(QUIET)mkdir -p $@

build/ruby: | build
	-$(QUIET)mkdir -p $@

# TODO(sissel): Update this to be like.. functional.
# TODO(sissel): Skip sigar?
# Run this one always? Hmm..
.PHONY: build/monolith
build/monolith: $(ELASTICSEARCH) $(JRUBY) vendor-gems | build
build/monolith: compile copy-ruby-files
	-$(QUIET)mkdir -p $@
	@# Unpack all the 3rdparty jars and any jars in gems
	$(QUIET)find $$PWD/vendor/bundle $$PWD/vendor/jar -name '*.jar' \
	| (cd $@; xargs -tn1 jar xf)
	@# Purge any extra files we don't need in META-INF (like manifests and
	@# signature files)
	-$(QUIET)rm -f $@/META-INF/*.LIST
	-$(QUIET)rm -f $@/META-INF/*.MF
	-$(QUIET)rm -f $@/META-INF/*.RSA
	-$(QUIET)rm -f $@/META-INF/*.SF
	-$(QUIET)rm -f $@/META-INF/NOTICE $@/META-INF/NOTICE.txt
	-$(QUIET)rm -f $@/META-INF/LICENSE $@/META-INF/LICENSE.txt

# Learned how to do pack gems up into the jar mostly from here:
# http://blog.nicksieger.com/articles/2009/01/10/jruby-1-1-6-gems-in-a-jar
VENDOR_DIR=$(shell ls -d vendor/bundle/*ruby/*)
jar: build/logstash-$(VERSION)-monolithic.jar
build/logstash-$(VERSION)-monolithic.jar: | build/monolith
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS=-C build/ruby .
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS+=-C build/monolith .
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS+=-C $(VENDOR_DIR) gems
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS+=-C $(VENDOR_DIR) specifications
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS+=-C lib logstash/web/public
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS+=-C lib logstash/web/views
build/logstash-$(VERSION)-monolithic.jar: JAR_ARGS+=patterns
build/logstash-$(VERSION)-monolithic.jar:
	$(QUIET)jar cfe $@ logstash.runner $(JAR_ARGS)
	$(QUIET)jar i $@

update-jar: copy-ruby-files
	$(QUIET)jar uf build/logstash-$(VERSION)-monolithic.jar -C build/ruby .

.PHONY: test
test: | $(JRUBY_CMD) vendor-elasticsearch
	$(QUIET)bash $(JRUBY_CMD) bin/logstash test

.PHONY: docs
docs: docgen doccopy docindex

doccopy: $(addprefix build/,$(shell git ls-files | grep '^docs/')) | build/docs
docindex: build/docs/index.html

docgen: $(addprefix build/docs/,$(subst lib/logstash/,,$(subst .rb,.html,$(PLUGIN_FILES))))

build/docs: build
	-$(QUIET)mkdir $@

build/docs/inputs build/docs/filters build/docs/outputs: | build/docs
	-$(QUIET)mkdir $@

# bluecloth gem doesn't work on jruby. Use ruby.
build/docs/inputs/%.html: lib/logstash/inputs/%.rb docs/docgen.rb docs/plugin-doc.html.erb | build/docs/inputs
	$(QUIET)ruby docs/docgen.rb -o build/docs $<
build/docs/filters/%.html: lib/logstash/filters/%.rb docs/docgen.rb docs/plugin-doc.html.erb | build/docs/filters
	$(QUIET)ruby docs/docgen.rb -o build/docs $<
build/docs/outputs/%.html: lib/logstash/outputs/%.rb docs/docgen.rb docs/plugin-doc.html.erb | build/docs/outputs
	$(QUIET)ruby docs/docgen.rb -o build/docs $<

build/docs/%: docs/% lib/logstash/version.rb Makefile
	@echo "Copying $< (to $@)"
	-$(QUIET)mkdir -p $(shell dirname $@)
	$(QUIET)cp $< $@
	$(QUIET)sed -i -re 's/%VERSION%/$(VERSION)/g' $@
	$(QUIET)sed -i -re 's/%ELASTICSEARCH_VERSION%/$(ELASTICSEARCH_VERSION)/g' $@

build/docs/index.html: $(addprefix build/docs/,$(subst lib/logstash/,,$(subst .rb,.html,$(PLUGIN_FILES))))
build/docs/index.html: docs/generate_index.rb lib/logstash/version.rb docs/index.html.erb Makefile
	ruby $< build/docs > $@
	$(QUIET)sed -i -re 's/%VERSION%/$(VERSION)/g' $@
	$(QUIET)sed -i -re 's/%ELASTICSEARCH_VERSION%/$(ELASTICSEARCH_VERSION)/g' $@

publish: | gem
	$(QUIET)$(WITH_JRUBY) gem push logstash-$(VERSION).gem

rpm: build/logstash-$(VERSION)-monolithic.jar
	rm -rf build/root
	mkdir -p build/root/opt/logstash
	cp -rp patterns build/root/opt/logstash/patterns
	cp build/logstash-$(VERSION)-monolithic.jar build/root/opt/logstash
	(cd build; fpm -t rpm -d jre -a noarch -n logstash -v $(VERSION) -s dir -C root opt)
