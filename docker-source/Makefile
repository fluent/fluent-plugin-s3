IMAGE=fluentd
TAG=custom-0

prep:
	cp ../pkg/*.gem pkg/

build: prep
	docker build . -t $(IMAGE):$(TAG)

run: build
	docker run --rm -ti $(IMAGE):$(TAG)
