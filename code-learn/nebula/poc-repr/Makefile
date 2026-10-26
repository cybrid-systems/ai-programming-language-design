CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Werror -Wno-mismatched-new-delete

.PHONY: all run names clean

all: measure

measure: measure.cpp beauty_item_names.txt
	$(CXX) $(CXXFLAGS) -o measure measure.cpp

beauty_item_names.txt: gen_beauty_names.py
	python3 gen_beauty_names.py --check 382 > beauty_item_names.txt

run: measure
	./measure beauty_item_names.txt

clean:
	rm -f measure
