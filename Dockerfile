FROM ruby:2.6-alpine
LABEL maintainer="ianfixes <ianfixes@gmail.com>"

ENV APPDIR=/app
ENV GEMSTASH_WORKDIR=/gemstash
ENV LOCAL_GEMS_DIR=/gems
ENV EMPTINESS_CHECK=seems_to_be_empty
ENV GEM_BUILD_DIR=/gem_build
ENV SERVER_PORT=9292
ENV GEM_KEY_NAME=test_key

RUN true \
  && mkdir -p $APPDIR \
  && mkdir -p $LOCAL_GEMS_DIR \
  && mkdir -p $GEMSTASH_WORKDIR \
  && mkdir -p $GEM_BUILD_DIR \
  && chmod a+w $GEMSTASH_WORKDIR \
  && touch ${LOCAL_GEMS_DIR}/${EMPTINESS_CHECK} \
  && true
WORKDIR /app

COPY Gemfile Gemfile.lock $APPDIR/

RUN true && \
  apk add --no-cache \
    build-base \
    openssl \
    sqlite-dev \
  && gem update --system 3.0.5 \
  && gem --version \
  && gem install bundler --version 2.1.4 \
  && bundle install -j2 \
  && apk del build-base \
  && true

COPY watch_and_publish.rb $APPDIR/


EXPOSE ${SERVER_PORT}
ENTRYPOINT ["bundle", "exec", "ruby", "watch_and_publish.rb"]
