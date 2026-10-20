#pragma once

#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace ctpl::opening {

// Native session IDs may include the full staging path, rather than a UUID.
// Keep the copied native value bounded without rejecting valid long paths.
inline bool valid_session_set(const std::vector<std::string>& sessions) {
    return sessions.size()==1&&!sessions.front().empty()&&sessions.front().size()<=16384&&
        sessions.front().find('\0')==std::string::npos;
}

// Value-only correlation. No engine or Qt pointer is dereferenced here. A file
// path must have passed OwnedSource validation before entering this state.
struct Document {
    std::string stable_id, source_path;
    std::uintptr_t window = 0;
};
struct Ticket {
    std::string request_id, template_id, path;
    std::uint64_t generation = 0;
};
class Correlation {
public:
    bool begin(Ticket ticket, std::uintptr_t window, std::vector<std::string> existing) {
        if (pending_ || !window || ticket.request_id.empty() || ticket.template_id.empty() || ticket.path.empty()) return false;
        ticket.generation = ++generation_;
        ticket_ = std::move(ticket);
        window_ = window;
        existing_ = std::move(existing);
        pending_ = true;
        return true;
    }
    bool candidate(const Document& document, bool source_unchanged) const {
        return pending_ && source_unchanged && !document.stable_id.empty() &&
            document.window == window_ && document.source_path == ticket_.path &&
            std::find(existing_.begin(), existing_.end(), document.stable_id) == existing_.end();
    }
    bool current(const Ticket& ticket) const {
        return pending_ && ticket.generation == ticket_.generation && ticket.request_id == ticket_.request_id;
    }
    // Reset runs once. If managed delivery is temporarily full, keep the exact
    // successful identity and retry publication without mutating Studio again.
    bool reset_complete(const Ticket& ticket,const std::string& stable_id) {
        if(!current(ticket)||stable_id.empty()||!completed_id_.empty())return false;
        completed_id_=stable_id;return true;
    }
    const std::string& completed_id() const { return completed_id_; }
    bool delivered(const Ticket& ticket,bool queue_accepted) {
        if(!current(ticket)||completed_id_.empty()||!queue_accepted)return false;
        cancel();return true;
    }
    const Ticket& ticket() const { return ticket_; }
    bool pending() const { return pending_; }
    void cancel() { pending_ = false; ++generation_; existing_.clear(); ticket_ = {}; completed_id_.clear(); window_ = 0; }
private:
    Ticket ticket_;
    std::string completed_id_;
    std::vector<std::string> existing_;
    std::uintptr_t window_ = 0;
    std::uint64_t generation_ = 0;
    bool pending_ = false;
};

} // namespace ctpl::opening
