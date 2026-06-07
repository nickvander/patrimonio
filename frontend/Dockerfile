FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .
# --pwa-strategy=none disables Flutter's offline service worker. This app is a
# self-hosted, always-online dashboard, so the SW buys nothing — and its
# CacheStorage caches assets independently of nginx's no-cache headers, which
# repeatedly served stale bundles after a rebuild (an updated fix looked like
# it "didn't take"). nginx already controls freshness; drop the SW.
RUN flutter build web --release --pwa-strategy=none

FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY security_headers.conf /etc/nginx/conf.d/security_headers.conf
COPY --from=build /app/build/web /usr/share/nginx/html
