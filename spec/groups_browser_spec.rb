require_relative 'support/desktop'

RSpec.describe 'Working in a shared group', :desktop do
  before do
    @host = desktop_host
    @lead, @member = %w[Lead Researcher].map { |name| host.agent(name) }
    @group = host.api('POST', '/api/groups', {name: 'Research Group', description: 'Compare products',
      lead: @lead, members: [@lead, @member]}, status: 201)
  end

  it 'sends a group message and keeps it separate from a member’s personal conversation' do
    start_desktop
    desktop.press('Groups')
    desktop.press(/Open Research Group/)
    desktop.fill(/Message Research Group/, 'Shared research request')
    desktop.press('Send message')
    desktop.see('Contract test reply')
    desktop.press('Open Researcher')
    desktop.see('Message Researcher')
    expect(desktop.text).not_to include('Shared research request')
    desktop.press('Groups')
    desktop.press(/Open Research Group/)
    expect(desktop.see('Shared research request')).to include('Contract test reply')
  end

  it 'shows deleted group tasks without carrying that filter into personal tasks' do
    path = "/api/groups/#{@group['id']}/tasks"
    task = host.api('POST', path, {title: 'Retired group research', assignee: @member}, status: 201)
    host.api('PUT', path + '/' + task['id'], {revision: task['revision'], deleted: true})
    start_desktop
    desktop.press('Groups')
    desktop.press(/Open Research Group/)
    desktop.press('Work menu')
    desktop.press('Tasks')
    desktop.press('Task status')
    desktop.press('Deleted')
    desktop.see('Retired group research')
    desktop.press('Sapis')
    desktop.press('Open ChiefSapi')
    desktop.press('Work menu')
    desktop.press('Tasks')
    desktop.see('No planned tasks')
    desktop.press('Task history')
    expect(desktop.text).to include('Planned', 'Executed')
    expect(desktop.text).not_to include('Deleted', 'Retired group research')
  end
end
