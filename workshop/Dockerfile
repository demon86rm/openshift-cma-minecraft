FROM docker.io/antora/antora as builder

# Build context is the repo root: Antora reads git history from it.
ADD . /antora/

RUN antora generate --stacktrace workshop/site.yml

FROM registry.access.redhat.com/rhscl/httpd-24-rhel7

COPY --from=builder /antora/workshop/gh-pages/ /var/www/html/
