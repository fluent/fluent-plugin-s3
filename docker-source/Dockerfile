FROM fluent/fluentd:edge

ARG PLUGINVERSION=1.5.0

USER root

COPY pkg/ /pkg/

RUN apk add --no-cache --update --virtual .build-deps \
        sudo build-base ruby-dev \
 && sudo gem install /pkg/fluent-plugin-s3-${PLUGINVERSION}.gem \
 && sudo gem sources --clear-all \
 && apk del .build-deps \
 && rm -rf /tmp/* /var/tmp/* /usr/lib/ruby/gems/*/cache/*.gem

COPY fluent.conf /fluentd/etc/

USER fluent

