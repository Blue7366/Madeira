// Exercise the same custom-resource + polymorphic-allocator pattern as FEX.
// The test binary must contain the backport, with no dynamic PMR imports.
#define _LIBCPP_DISABLE_AVAILABILITY
#include <cassert>
#include <cstddef>
#include <map>
#include <memory_resource>
#include <new>

struct Counts {
    int allocated = 0;
    int freed = 0;
    int destroyed = 0;
};

class Resource final : public std::pmr::memory_resource {
public:
    explicit Resource(Counts& counts) : counts_(counts) {}
    ~Resource() override { ++counts_.destroyed; }

private:
    void* do_allocate(std::size_t size, std::size_t alignment) override {
        ++counts_.allocated;
        return ::operator new(size, std::align_val_t(alignment));
    }
    void do_deallocate(void* ptr, std::size_t, std::size_t alignment) override {
        ++counts_.freed;
        ::operator delete(ptr, std::align_val_t(alignment));
    }
    bool do_is_equal(const memory_resource& other) const noexcept override {
        return this == &other;
    }
    Counts& counts_;
};

int main() {
    Counts counts;
    std::pmr::memory_resource* resource = new Resource(counts);
    assert(dynamic_cast<Resource*>(resource) != nullptr);
    std::pmr::polymorphic_allocator<std::byte> allocator(resource);
    using Map = std::pmr::map<int, int>;
    Map* map = allocator.new_object<Map>();
    assert(map->get_allocator().resource() == resource);
    for (int i = 0; i < 128; ++i) {
        map->emplace(i, i * i);
    }
    assert(map->at(11) == 121);
    assert(counts.allocated >= 129); // map object and its nodes use our resource
    allocator.delete_object(map);
    assert(counts.allocated == counts.freed);
    delete resource; // virtual dispatch reaches both derived and base destructors
    assert(counts.destroyed == 1);
}
