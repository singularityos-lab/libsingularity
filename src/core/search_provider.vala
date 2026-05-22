using GLib;
using Gdk;

namespace Singularity {

    public interface SearchProvider : Object {
        public abstract string id { get; }
        public abstract string name { get; }
        public abstract async List<SearchResult> search(string query, Cancellable? cancellable) throws Error;
    }

    public class SearchResult : Object {
        public string title { get; construct; }
        public string? description { get; construct; }
        public string? icon_name { get; construct; }
        public Icon? gicon { get; construct; }
        public string? action_id { get; construct; }
        public double score { get; set; default = 0.0; }
        public string? mime_type { get; set; default = null; }
        public SearchProvider provider { get; construct; }
        public signal void activated();

        public SearchResult(SearchProvider provider, string title, string? description = null, string? icon_name = null, Icon? gicon = null, string? action_id = null) {
            Object(
                provider: provider,
                title: title,
                description: description,
                icon_name: icon_name,
                gicon: gicon,
                action_id: action_id
            );
        }

        public virtual void activate() {
            activated();
        }
    }
}
