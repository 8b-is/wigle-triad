# ==============================================================================
# FlugOS 3-Node ESP32-S3 Offline Voice Mesh Makefile
# ==============================================================================
CC ?= gcc
CFLAGS := -O3 -std=c11 -Wall -Wextra -Werror -Icommon -Imain

.PHONY: all test pack clean

all: test pack

test:
	$(CC) $(CFLAGS) \
		common/flugos_mesh.c \
		main/node_ear.c \
		main/node_brain.c \
		main/node_mouth.c \
		tests/test_flugos_triad_sim.c \
		-lm -o /tmp/test_flugos_triad_sim
	/tmp/test_flugos_triad_sim

pack:
	uv run --script tools/pack_models.py --out build/model_data.bin

clean:
	rm -rf build /tmp/test_flugos_triad_sim
