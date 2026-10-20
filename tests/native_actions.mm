// Exercise the real native queue and ownership guards without engine APIs.
#include "../native/StartPageUI.mm"
#include <cassert>
#include <iostream>

std::vector<std::string> posted_commands;
void ctpl_post_command(const std::string& json) { posted_commands.push_back(json); }
bool ctpl_ui_set_image(std::uintptr_t, const std::string&) { return true; }
bool ctpl_ui_set_style_enum(std::uintptr_t, const std::string&, const std::string&) { return true; }
bool ctpl_ui_copy_text_style(std::uintptr_t, std::uintptr_t) { return false; }
std::string ctpl_ui_font_name(std::int64_t) { return {}; }

void click(ActionType type, const std::string& id = {}, std::uint64_t generation = 1, bool enabled = true) {
    EventContext context;
    context.enabled.store(enabled);
    context.action = {type, id, generation};
    on_click(&context, nullptr, 0);
}
void drain() { process_actions(); }
int main() {
    auto& ui = state();
    ui.active.store(true);
    ui.generation.store(1);
    receive_catalog(R"({"revision":1,"selectRevision":1,"selectedCategoryId":"personal","categories":[{"id":"personal","name":"Personal"},{"id":"games","name":"Games"}],"templates":[{"id":"own-a","name":"A","categoryId":"personal","owned":true},{"id":"builtin","name":"Official","categoryId":"personal","owned":false}]})");
    assert(ui.entries.size() == 1 && ui.selected == "personal");

    click(ActionType::Open, "own-a"); click(ActionType::Edit, "own-a"); drain();
    assert(posted_commands.size() == 2);
    assert(posted_commands[0].find("\"open\"") != std::string::npos);
    assert(posted_commands[1].find("\"edit\"") != std::string::npos);
    for (const auto& value : posted_commands) assert(value.find("remove") == std::string::npos);
    posted_commands.clear();

    click(ActionType::Open, "builtin"); click(ActionType::Edit, "builtin");
    click(ActionType::Open, "unknown"); click(ActionType::Edit, "unknown"); drain();
    assert(posted_commands.empty());

    click(ActionType::Category, "games"); click(ActionType::Import); drain();
    assert(ui.selected == "games" && posted_commands.size() == 1);
    assert(posted_commands[0].find("\"games\"") != std::string::npos);
    posted_commands.clear();
    click(ActionType::CategoryEdit, "games"); click(ActionType::CategoryEdit, "foreign"); drain();
    assert(posted_commands.size() == 1 && posted_commands[0].find("category_edit") != std::string::npos);
    posted_commands.clear();

    click(ActionType::Edit, "own-a", 1, false); click(ActionType::Edit, "own-a", 0); drain();
    assert(posted_commands.empty());
    click(ActionType::Edit, "own-a"); ui.entries.clear(); drain();
    assert(posted_commands.empty());
    click(ActionType::NewCategory); ui.generation.store(2); drain();
    assert(posted_commands.empty());
    click(ActionType::Official, {}, 2); drain();
    assert(ui.selected.empty());
    std::cout << "9 native action and ownership checks passed\n";
}
