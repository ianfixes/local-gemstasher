# Local Gemstash for Ruby Development in Docker Containers [![Available on Docker Hub](https://img.shields.io/docker/pulls/ianfixes/local_gemstasher.svg)](https://hub.docker.com/r/ianfixes/local_gemstasher) [![Docker Image version](https://img.shields.io/docker/v/ianfixes/local_gemstasher.svg)](https://hub.docker.com/r/ianfixes/local_gemstasher)

**Problem**: Specifying your gem dependencies by `path:` won't work if you are in a `docker build` environment unless you add your entire development directory to the build context.

**Solution**: A local gemstash server that runs in a docker container, monitoring your local gems for changes and automatically updating them on the local server when they do.


Presented here in hopes that it can be further refined by the rubygems.org team.

## Background

Let's say that you have a mix of public and private gems in development:

* `/path/to/development/corporate/private_gem`
* `/path/to/development/public/public_gem`
* `/path/to/development/corporate/private_project`

Ordinarily, your `/path/to/development/corporate/private_project/Gemfile` might say:

```ruby
source 'https://rubygems.org'

gem 'public_gem', '=1.1.1'

source 'https://private-gem-repo.org' do
  gem 'private_gem', '=2.2.2'
end
```

But during development, you might be working with unreleased versions of the dependencies.  You might change your `Gemfile` like this:

```ruby
source 'https://rubygems.org'

#gem 'public_gem', '=1.1.1'
gem 'public_gem', path: '../../public/public_gem'

source 'https://private-gem-repo.org' do
  #gem 'private_gem', '=2.2.2'
  gem 'private_gem', path: '../private_gem'
end
```

Now assume you want to test that application using Docker.  Your `/path/to/development/corporate/private_project/Dockerfile` might say:

```Dockerfile
FROM ruby:2.6-alpine

COPY Gemfile .
RUN gem install bundler && bundle install
```

but `docker build .` will fail because `../../public/public_gem` and `../private_gem` won't be in the build context.  e.g.:

```
 ---> Running in b6a85624a938
Successfully installed bundler-2.2.13
1 gem installed
The path `/public/public_gem` does not exist.
The command '/bin/sh -c gem install bundler && bundle install' returned a non-zero code: 13
```

Let's start the `local-gemstasher` server to fix that.

## Building the server image locally

We'll call it `local_gemstasher`.

```console
$ docker build -t local_gemstasher .
```


## Downloading the pre-built image

This image is available [on DockerHub]((https://hub.docker.com/r/ianfixes/local_gemstasher)), so without installing anything from github you can simply

```console
$ docker pull ianfixes/local_gemstasher
```

## Starting the server

Let's assume that you do your development in a directory called `/path/to/development`, and it conains the following:

```
.
├── _public
│   └──_public_gem
│      ├── public_gem.gemspec
│      └── ...
├── _corporate
│   └──_private_gem
│      ├── private_gem.gemspec
│      └── ...
```

We will need to map this directory to `/gems` in the container (which we can safely do as read-only).  We will then need to list the gem directories, relative to that base, that we want to monitor for changes.  In this case, those paths would be `public/public_gem` and `corporate/private_gem`.

The full invocation of `docker run` for our example is as follows:

```console
$ docker run --rm                        \
  --publish 9293:9292                    \
  --volume /path/to/development:/gems:ro \
  ianfixes/local_gemstasher              \
    public/public_gem                    \
    corporate/private_gem
```

This will launch the server on `http://localhost:9293`.  It will immediately find the available gems, build them, and push them to the local server.

It will also watch these gems for any changes (at the filesystem level) and **automatically rebuild and re-push them as necessary**.  (Note that this can involve a reboot of the internal server, because `gemstash` does not allow overwriting nor re-pushing a yanked gem version.  Such is life.)

## Using the server from Docker builds

No changes are required to your `Dockerfile`.

You will need to tell your `Gemfile` to use the mirrored server as a source.  Note that `host.docker.internal` is the server hostname from the perspective of a Docker build:

```ruby
source 'https://rubygems.org'

# wrap the old lines in the docker server source
# you may need to adjust version numbers as appropriate
source 'http://host.docker.internal:9293/private' do
  gem 'public_gem', '=1.1.1'
  gem 'private_gem', '=2.2.2'
end
```

### Gotchas

Note that when you `bundle install`, you will have cached the version of `public_gem` and `private_gem` that were available on the local_gemstash server at the time -- bundler will make no attempt to re-download them, and there doesn't seem to be an option to `--redownload` an individual gem in bundler.

If you are using local_gemstasher to support using local gems in a `docker build`, this should be no problem -- assuming that you have already worked around the issue of docker layer caching in some way (up to and including the `--no-cache` flag for `docker build`).

However, if your use case involves also installing to your local machine, you will need to make use of the following:

```console
$ gem uninstall --force --executables --ignore-dependencies <name of gem> \
  && bundle install
  && <whatever command you wanted to run>
```
