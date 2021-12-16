FROM alpine:3.15.0 AS build-common

RUN apk add --update-cache \
		git build-base cmake yasm \
		&& rm -rf /var/cache/apk/*


# build supercollider
FROM build-common AS supercollider
RUN apk add --update-cache \
	jack-dev libsndfile-dev alsa-lib-dev avahi-dev eudev-dev libxt-dev \
		&& rm -rf /var/cache/apk/*
WORKDIR /repos
RUN git clone --branch=3.12 --depth=1 --recurse-submodules https://github.com/supercollider/supercollider.git \
		&& rm -rf /repos/supercollider/.git \
		&& mkdir -p /repos/supercollider/build \
		&& cd /repos/supercollider/build \
		&& cmake -DCMAKE_PREFIX_PATH=/usr/lib/x86_64-linux-gnu/qt5/ \
			-DNATIVE=ON -DSC_QT=OFF -DSC_IDE=OFF \
			-DNO_X11=ON -DSC_EL=OFF -DSC_ABLETON_LINK=OFF .. \
			-DCMAKE_BUILD_TYPE=Debug \
		&& make -j12


FROM build-common AS ffmpeg
# Build & Install libmp3lame
RUN apk add --update-cache \
	lame-dev jack-dev \
	&& rm -rf /var/cache/apk/*
#WORKDIR /repos
#RUN git clone --depth=1 https://github.com/rbrito/lame.git
#WORKDIR lame
#RUN ./configure --prefix=/usr
#RUN make -j 12 install
#WORKDIR /repos
#RUN rm -fr lame

# Build ffmpeg, ffserver
WORKDIR /repos
RUN git clone --depth 1 https://github.com/efairbanks/FFmpeg.git ffmpeg
WORKDIR ffmpeg
RUN ./configure --enable-indev=jack --enable-libmp3lame --enable-nonfree --prefix=/usr --disable-shared --enable-static
RUN make -j 12



FROM build-common as quarks
WORKDIR /repos
RUN git clone --depth=1 https://github.com/musikinformatik/SuperDirt
RUN git clone --depth=1 https://github.com/tidalcycles/Dirt-Samples \
	&& rm -rf /repos/Dirt-Samples/.git
RUN git clone --depth=1 https://github.com/supercollider-quarks/Vowel


FROM build-common

# Install dependencies and audio tools
RUN apk add --update-cache \
		jack xvfb alsa-lib-dev lame-dev jack-dev \
		libsamplerate-dev xz \
# haskell-mode
		supervisor bash dropbear \
		wget ghc emacs-nox zlib-dev screen \
		openssh-server openssh \
		&& rm -rf /var/cache/apk/*

COPY --from=ffmpeg /repos/ffmpeg /repos/ffmpeg
WORKDIR /repos/ffmpeg
RUN cd /repos/ffmpeg && make install && cd .. && rm -fr ffmpeg

#COPY --from=ffmpeg /repos/lame /repos/lame
#WORKDIR /repos/lame
#RUN make install


# Initialize and configure sshd
RUN mkdir /var/run/sshd
RUN echo 'root:algorave' | chpasswd
RUN echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config

# SSH login fix. Otherwise user is kicked off after login
RUN mkdir /etc/dropbear
RUN dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key

# Expose sshd service
EXPOSE 22

# Expose ffserver streaming service
EXPOSE 8090

# Pull Tidal Emacs binding
RUN mkdir /repos/tidal
WORKDIR /repos
WORKDIR tidal
# Pin to version around 1.3.0.
RUN wget https://raw.githubusercontent.com/tidalcycles/Tidal/1.7.8/tidal.el

ENV HOME /root
WORKDIR /root

RUN ln -s /repos /root/repos
RUN ln -s /work /root/work

# Install tidal
RUN apk add --update-cache wget ghc cabal libffi-dev \
		&& rm -rf /var/cache/apk/*
RUN cabal update && cabal install --lib tidal-1.7.8 && rm -rf .cabal/packages/hackage.haskell.org/

COPY --from=supercollider /repos/supercollider /repos/supercollider
RUN apk add --update-cache \
		libsndfile-dev xvfb-run shadow \
		libxt-dev fftw-dev avahi-dev eudev-dev jack-example-clients \
		&& rm -rf /var/cache/apk/*
WORKDIR /repos/supercollider/build
RUN make install
#RUN ldconfig

# https://github.com/supercollider/supercollider/issues/2882#issuecomment-303006967
#RUN mv /usr/local/share/SuperCollider/SCClassLibrary/Common/GUI /usr/local/share/SuperCollider/SCClassLibrary/scide_scqt/GUI
#RUN mv /usr/local/share/SuperCollider/SCClassLibrary/JITLib/GUI /usr/local/share/SuperCollider/SCClassLibrary/scide_scqt/JITLibGUI

# Install default configurations
COPY configs/emacsrc /root/.emacs
COPY configs/emacsinstallrc /root/.emacsinstallrc
COPY configs/screenrc /root/.screenrc
COPY configs/ffserver.conf /root/ffserver.conf

# Install haskell-mode
RUN emacs --batch -l /root/.emacsinstallrc

# Install default Tidal files
COPY tidal/hello.tidal /root/hello.tidal

# Prepare scratch workspace for version control
RUN mkdir -p /work/scratchpool

# Install Tidebox supervisord config
COPY configs/tidebox.ini /etc/supervisor.d/tidebox.ini

# Copy inital supercollider/superdirt startup file
COPY configs/firststart.scd /root/.config/SuperCollider/startup.scd

COPY --from=quarks /repos/SuperDirt /root/.local/share/SuperCollider/downloaded-quarks/SuperDirt
COPY --from=quarks /repos/Dirt-Samples /root/.local/share/SuperCollider/downloaded-quarks/Dirt-Samples
COPY --from=quarks /repos/Vowel /root/.local/share/SuperCollider/downloaded-quarks/Vowel

# Make dummy sclang_conf.yaml to force sclang to recompile class library
RUN touch /root/sclang_conf.yaml

# Install Quarks
WORKDIR /root
# "echo |" is a workaround for https://github.com/supercollider/supercollider/issues/2655.
# Note: xvfb-run doesn't always clean up its X lock:
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=932070, so force it to run
# on screen :1 (with -n 1), a different screen from later xvfb-run (in
# supervisord config).
RUN echo | xvfb-run -n 1 sclang -l /root/sclang_conf.yaml

# Copy permanent supercollider/superdirt startup file
COPY configs/startup.scd /root/.config/SuperCollider/startup.scd

# set root shell to screen
RUN echo "/usr/bin/screen" >> /etc/shells
RUN usermod -s /usr/bin/screen root

RUN apk add valgrind

CMD ["/usr/bin/supervisord"]
