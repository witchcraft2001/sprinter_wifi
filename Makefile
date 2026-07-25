.PHONY: build package image test test-netup-busy test-uart-profiles clean

build:
	tools/build.sh

package:
	tools/package.sh

image:
	tools/image.sh

test: test-netup-busy test-uart-profiles
	tools/test-zmodem.sh

test-netup-busy:
	tools/test-netup-busy.sh

test-uart-profiles:
	tools/test-uart-profiles.sh

clean:
	rm -rf build
	rm -f distr/sprinter-net.zip distr/sprinter-esp_v.*.zip distr/sprinter-net.img
