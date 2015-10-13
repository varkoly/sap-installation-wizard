# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact SUSE Linux GmbH.
#
# ------------------------------------------------------------------------------
#
# Summary: In the wizard workflow, display a dialog to let user configure HANA firewall parameters.
# Authors: Howard Guo <hguo@suse.com>

require "yast"
Yast.import "UI"
Yast.import "Label"
Yast.import "Popup"
Yast.import "Service"
Yast.import "Package"
Yast.import "SAPInst"
Yast.import "HANAFirewall"

module SAPInstaller
    class ConfigHANAFirewallDialog
        include Yast::UIShortcuts
        include Yast::I18n
        include Yast::Logger
        
        def initialize
            textdomain "sap-installation-wizard"
        end
        
        # Return a ruby symbol that directs Yast Wizard workflow (for example :next, :back, :abort)
        def run
            if !Yast::SAPInst.instMasterType.downcase.match(/hana/)
                # This dialog is shown only after installing HANA.
                return :next
            end

            (@global_conf, @iface_conf, @init_num_ifaces) = Yast::HANAFirewall.Read
            @curr_iface_num = 0
            @all_svc_choices = Yast::HANAFirewall.GetAllHANAServiceNames + Yast::HANAFirewall.GetNonHANAServiceNames
            render_all
            render_for_iface
            return ui_event_loop
        end
        
        # Return a ruby symbol that directs Yast Wizard workflow (for example :next, :back, :abort)
        def ui_event_loop
            loop do
                case Yast::UI.UserInput
                when :profile_name
                    # Display profile description text when user choice changes
                    choice = Yast::UI.QueryWidget(Id(:profile_name), :Value)
                    Yast::UI.ChangeWidget(Id(:profile_desc), :Value, TUNING_PROFILES[choice]["desc"])
                    Yast::UI.RecalcLayout
                when :back
                    return :back
                when :abort, :cancel
                    return :abort
                when :num_ifaces
                    # Change number of network interfaces to display
                    new_num = Yast::UI.QueryWidget(Id(:num_ifaces), :Value)
                    Yast::UI.ChangeWidget(Id(:iface_num), :Items, (0..new_num-1).to_a.map{|i| i.to_s})
                    if @curr_iface_num >= new_num
                        @curr_iface_num = new_num - 1
                        render_for_iface
                    end
                when :iface_num
                    # Change the network interface being looked at
                    @curr_iface_num = Yast::UI.QueryWidget(Id(:iface_num), :Value).to_i
                    render_for_iface
                when :iface_name
                    # Change interface name
                    create_iface_conf_if_not_exist
                    @iface_conf[@curr_iface_num][:name] = Yast::UI.QueryWidget(Id(:iface_name), :Value).to_s
                when :add_standby_svc
                    # Add the chosen service name
                    choice = Yast::UI.QueryWidget(Id(:standby_svc), :CurrentItem)
                    if !choice
                        redo
                    end
                    create_iface_conf_if_not_exist
                    @iface_conf[@curr_iface_num][:svcs] += [choice]
                    render_for_iface
                when :add_manual_svc
                    # Add the manually entered service string
                    input = Yast::UI.QueryWidget(Id(:manual_svc), :Value).to_s.strip
                    if !input
                        redo
                    end
                    svc_cidr = input.split(/:/)
                    if svc_cidr.length != 2
                        Yast::Popup.Error(_("Please enter service name and CIDR in form: service_name:CIDR_block"))
                        redo
                    end
                    # Make sure that svc name is valid
                    if !@all_svc_choices.include?(svc_cidr[0])
                        Yast::Popup.Error(_("The service name does not seem to be valid.\n" +
                            "Available service names can be found in \"getent services\" output."))
                        redo
                    end
                    create_iface_conf_if_not_exist
                    if !@iface_conf[@curr_iface_num][:svcs].include?(input)
                        @iface_conf[@curr_iface_num][:svcs] += [input]
                        render_for_iface
                    end
                    Yast::UI.ChangeWidget(Id(:manual_svc), :Value, '')
                when :remove_standby_svc
                    # Remove a service from the chosen list
                    choice = Yast::UI.QueryWidget(Id(:active_svc), :CurrentItem)
                    if !choice
                        redo
                    end
                    @iface_conf[@curr_iface_num][:svcs] -= [choice]
                    render_for_iface
                else
                    # Proceed to write HANA firewall configuration and activate
                    # Double check SSH settings with user
                    enable_ssh = Yast::UI.QueryWidget(Id(:open_all_ssh), :Value)
                    print enable_ssh
                    if !enable_ssh && !Yast::Popup.YesNo(
                        _("You did not choose to enable SSH on all network interfaces.\n"+
                          "Please be aware that you should definitely open SSH port if you are installing SAP\n" +
                          "via SSH or VNC-over-SSH.\n\n" +
                          "Are you sure to proceed without enabling SSH on all network interfaces?"))
                        redo
                    end
                    # Apply new configuration and activate
                    @global_conf[:open_all_ssh] = enable_ssh
                    @global_conf[:enable_logging] = Yast::UI.QueryWidget(Id(:enable_logging), :Value)
                    Yast::HANAFirewall.Write(@global_conf, @iface_conf)
                    return :next
                end
            end
        end

        private
        def create_iface_conf_if_not_exist
            if !@iface_conf[@curr_iface_num]
                @iface_conf[@curr_iface_num] = {
                    :name => Yast::UI.QueryWidget(Id(:iface_name), :Value).to_s,
                    :svcs => []
                }
            end
        end

        def render_for_iface
            all_svcs = Yast::HANAFirewall.GetAllHANAServiceNames
            iface_svcs = []
            iface_name = ''
            if @iface_conf[@curr_iface_num]
                iface_svcs = @iface_conf[@curr_iface_num][:svcs]
                iface_name = @iface_conf[@curr_iface_num][:name]
            end
            remaining_choices = all_svcs - iface_svcs
            Yast::UI.ChangeWidget(Id(:iface_name), :Value, iface_name)
            Yast::UI.ChangeWidget(Id(:standby_svc), :Items, remaining_choices)
            Yast::UI.ChangeWidget(Id(:active_svc), :Items, iface_svcs)
        end

        def render_all
            Yast::Wizard.SetContents(
                _("Configure network firewall for HANA"),
                VBox(
                    Left(Frame(_("Global Firewall Options"), VBox(
                        Left(CheckBox(Id(:open_all_ssh), _("Enable SSH on all interfaces (recommended)"), @global_conf[:open_all_ssh])),
                        Left(CheckBox(Id(:enable_logging), _("Log blocked traffic"), @global_conf[:enable_logging])),
                        Left(HSquash(IntField(Id(:num_ifaces), Opt(:notify), _("Number of network interfaces in this HANA setup"), 1, 10, @init_num_ifaces)))
                    ))),
                    Frame(_("Choose HANA services applicable on each network interface"), VBox(
                        HBox(
                             Label(_("Interface number")),
                             ComboBox(Id(:iface_num), Opt(:notify), "", (0..@init_num_ifaces-1).to_a.map{|i| i.to_s}),
                             Label(_(" that corresponds to:")),
                             HSquash(ComboBox(Id(:iface_name), Opt(:notify), "", Yast::HANAFirewall.GetEligibleInterfaceNames))),
                        HBox(
                            # Left side shows list of available HANA services + manual entry textbox
                            HWeight(5, VBox(
                                SelectionBox(Id(:standby_svc), _("HANA services:"), []),
                                Left(Label(_("Other service and CIDR (example: https:10.0.0.0/8):"))),
                                HBox(
                                    InputField(Id(:manual_svc), Opt(:hstretch), ""),
                                    PushButton(Id(:add_manual_svc), _("Add →"))
                                )
                            )),
                            HWeight(2, VBox(
                                PushButton(Id(:add_standby_svc), _("Add →")),
                                PushButton(Id(:remove_standby_svc), _("← Remove")),
                            )),
                            # Right side shows list of chosen/manually entered service names
                            HWeight(5, SelectionBox(
                                Id(:active_svc),
                                _("Allowed services:"),
                                ["ntp", "ssh"]
                            ))
                        )
                    )),
                ),
                _("HANA firewall helps protecting your HANA database against harmful network traffic.\n" +
                  "Please enter HANA network interface names and choose allowed services for each network interface.\n" +
                  "If you are relying on SSH connection for this installation, please make sure to check \"Enable SSH\" checkbox.\n" +
                  "If you are adding other services, you can find a complete list of service names in \"/etc/services\" file.\n" +
                  "After the wizard finishes, you may continue to administrate HANA-firewall using command \"hana-firewall\"\n" +
                  "See \"man 8 hana-firewall\" for more help on HANA firewall administration."),
                true,
                true
            )
            Yast::Wizard.RestoreAbortButton
        end
    end
end