.PHONY: build package image test test-libman test-netup-busy test-uart-profiles test-send-defer test-mux-demux test-mux-cmd test-progress test-race-server racetest clean

build:
	tools/build.sh

package:
	tools/package.sh

image:
	tools/image.sh

test: test-libman test-netup-busy test-uart-profiles test-send-defer test-mux-demux test-mux-cmd test-progress test-race-server
	tools/test-zmodem.sh

test-libman:
	tools/test-libman.sh

test-netup-busy:
	tools/test-netup-busy.sh

test-uart-profiles:
	tools/test-uart-profiles.sh

test-send-defer:
	tools/test-send-defer.sh

test-mux-demux:
	tools/test-mux-demux.sh

test-mux-cmd:
	tools/test-mux-cmd.sh

test-progress:
	tools/test-progress.sh

test-race-server:
	python3 tools/test-race-server.py

# Developer-only SEND-race stress tool; NOT part of the distribution.
# Pair with tools/race_server.py running on the target host.
racetest:
	mkdir -p build
	sjasmplus --nologo --fullpath -I src/include -I src/lib \
	  --lst=build/RACETEST.lst --raw=build/RACETEST.EXE src/apps/racetest.asm
	@echo "Built build/RACETEST.EXE (dev tool, not packaged)"

clean:
	rm -rf build
	rm -f distr/sprinter-net.zip distr/sprinter-esp_v.*.zip distr/sprinter-net.img
