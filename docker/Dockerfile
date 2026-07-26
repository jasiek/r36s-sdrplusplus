# Build environment for the SDR++ PortMaster port.
#
# Based on the official PortMaster aarch64 builder (Ubuntu 20.04 focal,
# glibc 2.31, gcc 9.4). Matching glibc to the oldest supported CFW is the
# whole point: ArkOS on RK3326 is focal-era, so anything newer would produce
# binaries that refuse to start on the device.
ARG BASE_IMAGE=ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# SDR++ core deps + the source modules we enable + tooling for bundling and
# the offline smoke test (xvfb/llvmpipe let us actually launch the binary here).
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      file \
      git \
      patchelf \
      pkg-config \
      python3 \
      zip \
      libfftw3-dev \
      libglfw3-dev \
      libvolk2-dev \
      libzstd-dev \
      libairspy-dev \
      libairspyhf-dev \
      libhackrf-dev \
      libasound2-dev \
      librtlsdr-dev \
      libusb-1.0-0-dev \
      libgl1-mesa-dev \
      libglu1-mesa-dev \
      libgl1-mesa-dri \
      xvfb \
    && rm -rf /var/lib/apt/lists/*

# RtAudio, built ALSA-only.
#
# Ubuntu's librtaudio-dev has PulseAudio and JACK compiled in. Neither daemon
# exists on these handhelds, so both are dead weight - and expensive dead
# weight: linking them drags libpulse, libjack, libsystemd, libdbus,
# libapparmor, libsndfile, libFLAC, libvorbis and friends into the port, about
# fifteen libraries we would then have to ship and hope behave on a foreign
# host. Worse, RtAudio probes JACK and Pulse ahead of ALSA, so the most likely
# on-device symptom of leaving them in is simply no sound.
ARG RTAUDIO_VERSION=6.0.1
RUN git clone --depth 1 --branch ${RTAUDIO_VERSION} \
        https://github.com/thestk/rtaudio.git /tmp/rtaudio \
 && cmake -S /tmp/rtaudio -B /tmp/rtaudio/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON \
        -DRTAUDIO_API_ALSA=ON \
        -DRTAUDIO_API_PULSE=OFF \
        -DRTAUDIO_API_JACK=OFF \
        -DRTAUDIO_API_OSS=OFF \
        -DRTAUDIO_BUILD_TESTING=OFF \
 && cmake --build /tmp/rtaudio/build -j"$(nproc)" \
 && cmake --install /tmp/rtaudio/build \
 && ldconfig \
 && mkdir -p /usr/local/share/port-licenses \
 && cp /tmp/rtaudio/LICENSE /usr/local/share/port-licenses/LICENSE.librtaudio.txt \
 && rm -rf /tmp/rtaudio

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig

WORKDIR /workspace
