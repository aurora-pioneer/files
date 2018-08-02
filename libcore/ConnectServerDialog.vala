/*
* Copyright (c) 2015-2018 elementary LLC. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1335 USA.
*
* Authored by: Corentin Noël <corentin@elementary.io>
*/

public class PF.ConnectServerDialog : Gtk.Dialog {
    [Flags]
    private enum WidgetsFlag {
        NONE,
        DEFAULT,
        SHARE,
        PORT,
        USER,
        DOMAIN,
        ANONYMOUS
    }

    private struct MethodInfo {
        string scheme;
        WidgetsFlag flags;
        ushort port;
        string description;
    }

    private MethodInfo[] methods = {
        MethodInfo () {
            scheme = "ftp",
            flags = WidgetsFlag.ANONYMOUS | WidgetsFlag.PORT,
            port = 21,
            description = _("Public FTP")
        },
        MethodInfo () {
            scheme = "ftp",
            flags = WidgetsFlag.PORT | WidgetsFlag.USER,
            port = 21,
            description = _("FTP (with login)")
        },
        /* FIXME: we need to alias ssh to sftp */
        MethodInfo () {
            scheme = "sftp",
            flags = WidgetsFlag.PORT | WidgetsFlag.USER,
            port = 22,
            description = _("SSH")
        },
        MethodInfo () {
            scheme = "afp",
            flags = WidgetsFlag.PORT | WidgetsFlag.USER,
            port = 548,
            description = _("AFP (Apple Filing Protocol)")
        },
        MethodInfo () {
            scheme = "smb",
            flags = WidgetsFlag.SHARE | WidgetsFlag.USER | WidgetsFlag.DOMAIN,
            port = 0,
            description = _("Windows share")
        },
        MethodInfo () {
            scheme = "dav",
            flags = WidgetsFlag.PORT | WidgetsFlag.USER,
            port = 80,
            description = _("WebDAV (HTTP)")
        },
        /* FIXME: hrm, shouldn't it work? */
        MethodInfo () {
            scheme = "davs",
            flags = WidgetsFlag.PORT | WidgetsFlag.USER,
            port = 443,
            description = _("Secure WebDAV (HTTPS)")
        }
    };

    private Gtk.InfoBar info_bar;
    private DetailEntry server_entry;
    private Gtk.SpinButton port_spinbutton;
    private DetailEntry share_entry;
    private Gtk.ComboBox type_combobox;
    private DetailEntry folder_entry;
    private DetailEntry domain_entry;
    private DetailEntry user_entry;
    private DetailEntry password_entry;
    private Gtk.CheckButton remember_checkbutton;
    private Gtk.Button connect_button;
    private Gtk.Button continue_button;
    private Gtk.Button cancel_button;
    private Granite.HeaderLabel user_header_label;
    private Gtk.Label info_label;
    private Gtk.Stack stack;
    private GLib.Cancellable? mount_cancellable;

    public string server_uri {get; private set; default = "";}

    public ConnectServerDialog (Gtk.Window window) {
        Object (
            transient_for: window
        );

        var t = new Gtk.Label (_("Connect to Server"));
        t.get_style_context ().add_class (Granite.STYLE_CLASS_PRIMARY_LABEL);
        set_titlebar (t);
        show_all ();
        type_combobox.active = 0;
    }

    construct {
        deletable = false;
        resizable = false;

        info_bar = new Gtk.InfoBar ();
        info_bar.message_type = Gtk.MessageType.INFO;
        info_bar.no_show_all = true;
        info_bar.get_style_context ().add_class (Gtk.STYLE_CLASS_FRAME);
        info_label = new Gtk.Label (null);
        info_bar.get_content_area ().add (info_label);
        info_bar.hide ();

        var server_header_label = new Granite.HeaderLabel (_("Server Details"));

        server_entry = new DetailEntry (_("Server name or IP address"));
        var server_label = new DetailLabel (_("Server:"), server_entry);

        port_spinbutton = new Gtk.SpinButton.with_range (0, ushort.MAX, 1);
        port_spinbutton.digits = 0;
        port_spinbutton.numeric = true;
        port_spinbutton.update_policy = Gtk.SpinButtonUpdatePolicy.IF_VALID;
        var port_label = new DetailLabel (_("Port:"), port_spinbutton);
        port_label.xalign = 1;


        var type_store = new Gtk.ListStore (2, typeof (MethodInfo), typeof (string));
        type_combobox = new Gtk.ComboBox.with_model (type_store);
        var renderer = new Gtk.CellRendererText ();
        type_combobox.pack_start (renderer, true);
        type_combobox.add_attribute (renderer, "text", 1);
        var type_label = new DetailLabel (_("Type:"), type_combobox);


        share_entry = new DetailEntry (_("Name of share on server"));
        var share_label = new DetailLabel (_("Share:"), share_entry);

        folder_entry = new DetailEntry (_("Path of shared folder on server"), "/");
        var folder_label = new DetailLabel (_("Folder:"), folder_entry);

        user_header_label = new Granite.HeaderLabel (_("User Details"));

        domain_entry = new DetailEntry (_("Name of Windows domain"), "WORKGROUP");
        var domain_label = new DetailLabel (_("Domain name:"), domain_entry);

        user_entry = new DetailEntry (_("Name of user on server"), Environment.get_user_name ());
        var user_label = new DetailLabel (_("User name:"), user_entry);

        password_entry = new DetailEntry ();
        password_entry.input_purpose = Gtk.InputPurpose.PASSWORD;
        password_entry.visibility = false;
        var password_label = new DetailLabel (_("Password:"), password_entry);

        remember_checkbutton = new Gtk.CheckButton.with_label (_("Remember this password"));
        password_entry.bind_property ("visible", remember_checkbutton, "visible", GLib.BindingFlags.DEFAULT);

        cancel_button = new Gtk.Button.with_label (_("Cancel"));
        cancel_button.show ();
        cancel_button.clicked.connect (on_cancel_clicked);

        connect_button = new Gtk.Button.with_label (_("Connect"));
        connect_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
        connect_button.can_default = true;
        connect_button.no_show_all = true;
        connect_button.show ();
        connect_button.clicked.connect (on_connect_clicked);

        continue_button = new Gtk.Button.with_label (_("Continue"));
        continue_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
        continue_button.can_default = true;
        continue_button.no_show_all = true;
        continue_button.clicked.connect (on_continue_clicked);

        var button_box = new Gtk.ButtonBox (Gtk.Orientation.HORIZONTAL);
        button_box.layout_style = Gtk.ButtonBoxStyle.END;
        button_box.margin_top = 12;

        cancel_button.margin = 3;
        connect_button.margin = 3;
        continue_button.margin = 3;

        button_box.add (cancel_button);
        button_box.add (connect_button);
        button_box.add (continue_button);

        var grid = new Gtk.Grid ();
        grid.margin_start = grid.margin_end = 12;
        grid.margin_bottom = 6;
        grid.row_spacing = 6;
        grid.column_spacing = 3;
        grid.attach (server_header_label, 0, 0, 6, 1);

        grid.attach (server_label, 0, 1, 1, 1);
        grid.attach (server_entry, 1, 1, 3, 1);
        grid.attach (port_label, 4, 1, 1, 1);
        grid.attach (port_spinbutton, 5, 1, 1, 1);
        grid.attach (type_label, 0, 2, 1, 1);
        grid.attach (type_combobox, 1, 2, 3, 1);

        grid.attach (share_label, 0, 3, 1, 1);
        grid.attach (share_entry, 1, 3, 3, 1);
        grid.attach (folder_label, 0, 4, 1, 1);
        grid.attach (folder_entry, 1, 4, 5, 1);

        grid.attach (user_header_label, 0, 5, 6, 1);

        grid.attach (domain_label, 0, 6, 1, 1);
        grid.attach (domain_entry, 1, 6, 5, 1);
        grid.attach (user_label, 0, 7, 1, 1);
        grid.attach (user_entry, 1, 7, 5, 1);
        grid.attach (password_label, 0, 8, 1, 1);
        grid.attach (password_entry, 1, 8, 5, 1);

        grid.attach (remember_checkbutton, 0, 9, 5, 1);

        var content_grid = new Gtk.Grid ();
        content_grid.orientation = Gtk.Orientation.VERTICAL;
        content_grid.add (info_bar);
        content_grid.add (grid);

        var connecting_spinner = new Gtk.Spinner ();
        connecting_spinner.start ();

        var connecting_label = new Gtk.Label (_("Connecting…"));

        var connecting_grid = new Gtk.Grid ();
        connecting_grid.orientation = Gtk.Orientation.VERTICAL;
        connecting_grid.row_spacing = 6;
        connecting_grid.halign = Gtk.Align.CENTER;
        connecting_grid.valign = Gtk.Align.CENTER;
        connecting_grid.add (connecting_label);
        connecting_grid.add (connecting_spinner);

        stack = new Gtk.Stack ();
        stack.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
        stack.add_named (content_grid, "content");
        stack.add_named (connecting_grid, "connecting");

        get_content_area ().add (stack);
        get_content_area ().add (button_box);

        /* skip methods that don't have corresponding gvfs uri schemes */
        unowned string[] supported_schemes = GLib.Vfs.get_default ().get_supported_uri_schemes ();
        foreach (var method in methods) {
            if (!(method.scheme in supported_schemes)) {
                continue;
            }

            Gtk.TreeIter iter;
            type_store.append (out iter);
            type_store.set (iter, 0, method, 1, method.description);
        }

        type_combobox.changed.connect (() => type_changed ());

        server_entry.changed.connect (() => {
            connect_button.sensitive = valid_entries ();
        });

        user_entry.changed.connect (() => {
            connect_button.sensitive = valid_entries ();
            user_entry.needs_attention = false;
        });

        domain_entry.changed.connect (() => {
            connect_button.sensitive = valid_entries ();
            domain_entry.needs_attention = false;
        });

        password_entry.changed.connect (() => {
            connect_button.sensitive = valid_entries ();
            password_entry.needs_attention = false;
        });
    }

    private void type_changed () {
        Gtk.TreeIter iter;
        if (!type_combobox.get_active_iter (out iter)) {
            critical ("Error with GVFS");
        }

        Value val;
        type_combobox.get_model ().get_value (iter, 0, out val);
        MethodInfo* method_info = (MethodInfo*)val.get_boxed ();
        share_entry.visible = WidgetsFlag.SHARE in method_info.flags;
        port_spinbutton.sensitive = WidgetsFlag.PORT in method_info.flags;
        port_spinbutton.value = method_info.port;
        user_header_label.visible = WidgetsFlag.USER in method_info.flags || WidgetsFlag.DOMAIN in method_info.flags;
        user_entry.visible = WidgetsFlag.USER in method_info.flags;
        password_entry.visible = WidgetsFlag.USER in method_info.flags;
        domain_entry.visible = WidgetsFlag.DOMAIN in method_info.flags;

        password_entry.activates_default = password_entry.visible;
        user_entry.activates_default = user_entry.visible && !password_entry.visible;
        server_entry.activates_default = !user_entry.visible;
        share_entry.activates_default = server_entry.activates_default;

        show_connect_button ();
        info_bar.visible = false;

    }

    private void show_connect_button () {
        connect_button.visible = true;
        continue_button.visible = false;
        connect_button.sensitive = valid_entries ();
        connect_button.grab_default ();
    }

    private void show_continue_button () {
        connect_button.visible = false;
        continue_button.visible = true;
        continue_button.sensitive = false; /* something has to change */
        continue_button.grab_default ();
    }

    private void show_connecting (bool show_connecting) {
        if (show_connecting) {
            info_bar.hide ();
            stack.visible_child_name = "connecting";
            connect_button.visible = false;
            connect_button.sensitive = false;
            continue_button.visible = false;
            continue_button.sensitive = false;
        } else {
            stack.visible_child_name = "content";
            show_connect_button ();
        }
    }

    private void verify_details () {
        var loop = new MainLoop ();
        continue_button.set_data ("loop", loop);
        type_combobox.sensitive = false;
        info_bar.message_type = Gtk.MessageType.WARNING;
        info_label.label = _("Please verify your user details.");
        show_continue_button ();
        show_info ();
        loop.run ();

        continue_button.set_data ("loop", null);
        show_connect_button ();
    }

    private void error (string error_message) {
        info_bar.message_type = Gtk.MessageType.ERROR;
        info_label.label = error_message;
        show_info ();
    }

    private void show_info () {
        show_connecting (false);
        info_bar.no_show_all = false;
        info_bar.show_all ();
    }

    private bool valid_server () {
        /* TODO Find a better way of validating server entry */
        return server_entry.text.length > 3;
    }

    private bool valid_user () {
        return !password_entry.needs_attention;
    }

    private bool valid_domain () {
        return !domain_entry.needs_attention;
    }

    private bool valid_password () {
        return !password_entry.needs_attention;
    }

    private bool valid_entries () {
        info_bar.visible = false;
        return valid_server () && valid_user () && valid_domain () && valid_password ();
    }



    private async void connect_to_server () {
        Gtk.TreeIter iter;
        if (!type_combobox.get_active_iter (out iter)) {
            return;
        }

        Value val;
        type_combobox.get_model ().get_value (iter, 0, out val);
        MethodInfo* method_info = (MethodInfo*)val.get_boxed ();
        var scheme = method_info.scheme + "://";
        var server = server_entry.text.replace (scheme, "");
        string user;
        if (WidgetsFlag.ANONYMOUS in method_info.flags) {
            user = "anonymous";
        } else {
            user = user_entry.text;
        }

        if (WidgetsFlag.DOMAIN in method_info.flags) {
            user = string.join (";", domain_entry.text, user);
        }

        string initial_path;
        if (WidgetsFlag.SHARE in method_info.flags) {
            initial_path = GLib.Path.build_filename ("/", share_entry.text);
        } else {
            initial_path = "";
        }

        string folder = GLib.Path.build_filename (initial_path, folder_entry.text);
        folder = GLib.Uri.escape_string (folder, GLib.Uri.RESERVED_CHARS_ALLOWED_IN_PATH, false);

        var uri = scheme;
        if (user != "") {
            uri += user + "@";
        }

        uri += server;
        if (port_spinbutton.value > 0) {
            uri += ":%u".printf ((uint) port_spinbutton.value);
        }

        uri += folder;
        var location = File.new_for_uri (uri);

        var operation = new Marlin.ConnectServer.Operation (this);
        mount_cancellable = new GLib.Cancellable ();
        try {
            server_uri = uri;
            yield location.mount_enclosing_volume (GLib.MountMountFlags.NONE, operation, mount_cancellable);
        } catch (GLib.IOError.ALREADY_MOUNTED e) {
            /* not an error - just navigate to location */
        } catch (Error e) {
            error (e.message);
            return;
        } finally {
            mount_cancellable = null;
        }

        response (Gtk.ResponseType.OK);
        return;
    }

    /* Called back from ConnectServerOperation.vala during the mount operation if info missing */
    public async bool fill_details_async (GLib.MountOperation mount_operation,
                                          string default_user,
                                          string default_domain,
                                          GLib.AskPasswordFlags askpassword_flags) {
        var set_flags = askpassword_flags;
        if (GLib.AskPasswordFlags.NEED_PASSWORD in askpassword_flags) {
            var password = password_entry.text;
            if (password != null && password != "") {
                mount_operation.password = password;
                set_flags ^= GLib.AskPasswordFlags.NEED_PASSWORD;
            }
        }

        if (GLib.AskPasswordFlags.NEED_USERNAME in askpassword_flags) {
            var username = user_entry.text;
            if (username != null && username != "") {
                mount_operation.username = username;
                set_flags ^= GLib.AskPasswordFlags.NEED_USERNAME;
            }
        }

        if (GLib.AskPasswordFlags.NEED_DOMAIN in askpassword_flags) {
            var domain = domain_entry.text;
            if (domain != null && domain != "") {
                mount_operation.domain = domain;
                set_flags ^= GLib.AskPasswordFlags.NEED_DOMAIN;
            }
        }

        var need_mask = GLib.AskPasswordFlags.NEED_PASSWORD
                        | GLib.AskPasswordFlags.NEED_USERNAME
                        | GLib.AskPasswordFlags.NEED_DOMAIN;

        if ((set_flags & need_mask) == 0) {
            return true; /* HANDLED */
        }

        if (GLib.AskPasswordFlags.NEED_PASSWORD in askpassword_flags) {
            password_entry.needs_attention = true;
        }

        if (GLib.AskPasswordFlags.NEED_USERNAME in askpassword_flags) {
            if (default_user != null && default_user != "") {
                user_entry.text = default_user;
            } else {
                user_entry.needs_attention = true;
            }
        }

        if (GLib.AskPasswordFlags.NEED_DOMAIN in askpassword_flags) {
            if (default_domain != null && default_domain != "") {
                domain_entry.text = default_domain;
            } else {
                domain_entry.needs_attention = true;
            }
        }

        if (!(GLib.AskPasswordFlags.SAVING_SUPPORTED in askpassword_flags)) {
            remember_checkbutton.sensitive = false;
            remember_checkbutton.active = false;
        }

        verify_details (); /* This blocks current main loop until continue button clicked/activated */

        if (mount_cancellable.is_cancelled ()) {
            return false; /* ABORT */
        } else {
            if (GLib.AskPasswordFlags.NEED_PASSWORD in askpassword_flags) {
                mount_operation.password = password_entry.text;
            }

            if (GLib.AskPasswordFlags.NEED_USERNAME in askpassword_flags) {
                mount_operation.username = user_entry.text;
            }

            if (GLib.AskPasswordFlags.NEED_DOMAIN in askpassword_flags) {
                mount_operation.domain = domain_entry.text;
            }

            if (GLib.AskPasswordFlags.SAVING_SUPPORTED in askpassword_flags) {
                mount_operation.password_save = remember_checkbutton.active ? GLib.PasswordSave.PERMANENTLY : GLib.PasswordSave.NEVER;
            }

            return true;
        }
    }

    private void on_connect_clicked () {
        show_connecting (true);
        connect_to_server.begin ();
    }

    private void on_cancel_clicked () {
        void* loop = continue_button.get_data ("loop");
        if (loop != null) {
            type_combobox.sensitive = true;
            ((MainLoop)loop).quit ();
        }

       if (mount_cancellable != null && !mount_cancellable.is_cancelled ()) {
            mount_cancellable.cancel ();
        } else {
            response (Gtk.ResponseType.CANCEL);
        }
    }

    private void on_continue_clicked () {
        void* loop = continue_button.get_data ("loop");
        if (loop != null) {
            ((MainLoop)loop).quit ();
        }
    }

    private class DetailEntry : Gtk.Entry {
        public bool needs_attention {
            get {
                return is_needing_attention ();
            }

            set {
                if (value) {
                    add_needs_attention ();
                } else {
                    remove_needs_attention ();
                }
            }
        }

        construct {
            activates_default = true;
            text = "";
        }

        public DetailEntry (string tooltip = "", string _default = "") {
            Object (
                text: _default,
                tooltip_text: tooltip
            );
        }

        private bool is_needing_attention () {
            return visible && get_style_context ().has_class (Gtk.STYLE_CLASS_NEEDS_ATTENTION);
        }

        private void remove_needs_attention () {
            if (get_style_context ().has_class (Gtk.STYLE_CLASS_NEEDS_ATTENTION)) {
                get_style_context ().remove_class (Gtk.STYLE_CLASS_NEEDS_ATTENTION);
            }
        }

        private void add_needs_attention () {
            if (!get_style_context ().has_class (Gtk.STYLE_CLASS_NEEDS_ATTENTION)) {
                get_style_context ().add_class (Gtk.STYLE_CLASS_NEEDS_ATTENTION);
            }
        }
    }

    private class DetailLabel : Gtk.Label {
        public Gtk.Widget? linked_widget {get; construct;}

        public DetailLabel (string label, Gtk.Widget linked_widget) {
           Object (
                label: label,
                xalign: 0,
                linked_widget: linked_widget
            );

            linked_widget.bind_property ("visible", this, "visible", GLib.BindingFlags.SYNC_CREATE);

        }
    }
}