FROM fluent/fluentd:edge

ARG  VERSION=1.4.1

USER root

COPY fluent-plugin-s3-$VERSION.gem /

RUN  gem install /fluent-plugin-s3-$VERSION.gem --no-document

USER fluent
