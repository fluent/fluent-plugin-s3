all: build

gem: clean
	gem build fluent-plugin-s3

build: gem
	docker build -t fluentd-custom:edge .

clean:
	gem clean;
	rm -f fluent-plugin-s3*.gem
