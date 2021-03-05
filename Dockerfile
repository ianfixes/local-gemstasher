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
  # && gem install gemstash --version 2.1.0 \
  # && sh -c 'which gemstash' \
  # && gemstash --version \
  && gem update --system 3.0.5 \
  && gem --version \
  && gem install bundler --version 2.1.4 \
  && bundle install -j2 \
  && apk del build-base \
  && true

# RUN true \
#   && mkdir -p ~/.gem \
#   && touch ~/.gem/credentials \
#   && chmod 600 ~/.gem/credentials \
#   && echo "---" > ~/.gem/credentials \
#   && bundle exec gemstash authorize | awk -F": " "{print \":$GEM_KEY_NAME: \" \$2}" >> ~/.gem/credentials \
#   && cat ~/.gem/credentials

# build dummy gem /foo.gem
RUN true \
  && cd / \
  && bundle gem foo --no-exe --no-ext --no-mit --no-coc \
  && cd foo \
  && cat foo.gemspec \
     | sed 's/git ls-files -z/find . -print0 -type f/g' \
     | sed 's/TODO: //g' \
     | grep -v email \
     | grep -v URL \
     | grep -v spec.metadata \
     > foo2.gemspec \
#  && cat foo2.gemspec \
  && mv foo2.gemspec foo.gemspec \
  && gem build foo.gemspec -o /foo.gem


COPY watch_and_publish.rb $APPDIR/


#VOLUME /var/lib/gemstash
EXPOSE ${SERVER_PORT}
#CMD [ "/app/bin/start.sh" ]
ENTRYPOINT ["bundle", "exec", "ruby", "watch_and_publish.rb"]
