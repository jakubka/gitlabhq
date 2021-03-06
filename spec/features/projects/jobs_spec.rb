require 'spec_helper'
require 'tempfile'

feature 'Jobs', :feature do
  let(:user) { create(:user) }
  let(:user_access_level) { :developer }
  let(:project) { create(:project) }
  let(:namespace) { project.namespace }
  let(:pipeline) { create(:ci_pipeline, project: project) }

  let(:job) { create(:ci_build, :trace, pipeline: pipeline) }
  let(:job2) { create(:ci_build) }

  let(:artifacts_file) do
    fixture_file_upload(Rails.root + 'spec/fixtures/banana_sample.gif', 'image/gif')
  end

  before do
    project.team << [user, user_access_level]
    login_as(user)
  end

  describe "GET /:project/jobs" do
    let!(:job) { create(:ci_build,  pipeline: pipeline) }

    context "Pending scope" do
      before do
        visit namespace_project_jobs_path(project.namespace, project, scope: :pending)
      end

      it "shows Pending tab jobs" do
        expect(page).to have_link 'Cancel running'
        expect(page).to have_selector('.nav-links li.active', text: 'Pending')
        expect(page).to have_content job.short_sha
        expect(page).to have_content job.ref
        expect(page).to have_content job.name
      end
    end

    context "Running scope" do
      before do
        job.run!
        visit namespace_project_jobs_path(project.namespace, project, scope: :running)
      end

      it "shows Running tab jobs" do
        expect(page).to have_selector('.nav-links li.active', text: 'Running')
        expect(page).to have_link 'Cancel running'
        expect(page).to have_content job.short_sha
        expect(page).to have_content job.ref
        expect(page).to have_content job.name
      end
    end

    context "Finished scope" do
      before do
        job.run!
        visit namespace_project_jobs_path(project.namespace, project, scope: :finished)
      end

      it "shows Finished tab jobs" do
        expect(page).to have_selector('.nav-links li.active', text: 'Finished')
        expect(page).to have_content 'No jobs to show'
        expect(page).to have_link 'Cancel running'
      end
    end

    context "All jobs" do
      before do
        project.builds.running_or_pending.each(&:success)
        visit namespace_project_jobs_path(project.namespace, project)
      end

      it "shows All tab jobs" do
        expect(page).to have_selector('.nav-links li.active', text: 'All')
        expect(page).to have_content job.short_sha
        expect(page).to have_content job.ref
        expect(page).to have_content job.name
        expect(page).not_to have_link 'Cancel running'
      end
    end

    context "when visiting old URL" do
      let(:jobs_url) do
        namespace_project_jobs_path(project.namespace, project)
      end

      before do
        visit jobs_url.sub('/-/jobs', '/builds')
      end

      it "redirects to new URL" do
        expect(page.current_path).to eq(jobs_url)
      end
    end
  end

  describe "POST /:project/jobs/:id/cancel_all" do
    before do
      job.run!
      visit namespace_project_jobs_path(project.namespace, project)
      click_link "Cancel running"
    end

    it 'shows all necessary content' do
      expect(page).to have_selector('.nav-links li.active', text: 'All')
      expect(page).to have_content 'canceled'
      expect(page).to have_content job.short_sha
      expect(page).to have_content job.ref
      expect(page).to have_content job.name
      expect(page).not_to have_link 'Cancel running'
    end
  end

  describe "GET /:project/jobs/:id" do
    context "Job from project" do
      let(:job) { create(:ci_build, :success, pipeline: pipeline) }

      before do
        visit namespace_project_job_path(project.namespace, project, job)
      end

      it 'shows status name', :js do
        expect(page).to have_css('.ci-status.ci-success', text: 'passed')
      end

      it 'shows commit`s data' do
        expect(page.status_code).to eq(200)
        expect(page).to have_content pipeline.sha[0..7]
        expect(page).to have_content pipeline.git_commit_message
        expect(page).to have_content pipeline.git_author_name
      end

      it 'shows active job' do
        expect(page).to have_selector('.build-job.active')
      end
    end

    context 'when job is not running', :js do
      let(:job) { create(:ci_build, :success, pipeline: pipeline) }

      before do
        visit namespace_project_job_path(project.namespace, project, job)
      end

      it 'shows retry button' do
        expect(page).to have_link('Retry')
      end

      context 'if job passed' do
        it 'does not show New issue button' do
          expect(page).not_to have_link('New issue')
        end
      end

      context 'if job failed' do
        let(:job) { create(:ci_build, :failed, pipeline: pipeline) }

        before do
          visit namespace_project_job_path(namespace, project, job)
        end

        it 'shows New issue button' do
          expect(page).to have_link('New issue')
        end

        it 'links to issues/new with the title and description filled in' do
          button_title = "Build Failed ##{job.id}"
          job_path = namespace_project_job_path(namespace, project, job)
          options = { issue: { title: button_title, description: job_path } }

          href = new_namespace_project_issue_path(namespace, project, options)

          page.within('.header-action-buttons') do
            expect(find('.js-new-issue')['href']).to include(href)
          end
        end
      end
    end

    context "Job from other project" do
      before do
        visit namespace_project_job_path(project.namespace, project, job2)
      end

      it { expect(page.status_code).to eq(404) }
    end

    context "Download artifacts" do
      before do
        job.update_attributes(artifacts_file: artifacts_file)
        visit namespace_project_job_path(project.namespace, project, job)
      end

      it 'has button to download artifacts' do
        expect(page).to have_content 'Download'
      end
    end

    context 'Artifacts expire date' do
      before do
        job.update_attributes(artifacts_file: artifacts_file,
                              artifacts_expire_at: expire_at)

        visit namespace_project_job_path(project.namespace, project, job)
      end

      context 'no expire date defined' do
        let(:expire_at) { nil }

        it 'does not have the Keep button' do
          expect(page).not_to have_content 'Keep'
        end
      end

      context 'when expire date is defined' do
        let(:expire_at) { Time.now + 7.days }

        context 'when user has ability to update job' do
          it 'keeps artifacts when keep button is clicked' do
            expect(page).to have_content 'The artifacts will be removed'

            click_link 'Keep'

            expect(page).to have_no_link 'Keep'
            expect(page).to have_no_content 'The artifacts will be removed'
          end
        end

        context 'when user does not have ability to update job' do
          let(:user_access_level) { :guest }

          it 'does not have keep button' do
            expect(page).to have_no_link 'Keep'
          end
        end
      end

      context 'when artifacts expired' do
        let(:expire_at) { Time.now - 7.days }

        it 'does not have the Keep button' do
          expect(page).to have_content 'The artifacts were removed'
          expect(page).not_to have_link 'Keep'
        end
      end
    end

    context "when visiting old URL" do
      let(:job_url) do
        namespace_project_job_path(project.namespace, project, job)
      end

      before do
        visit job_url.sub('/-/jobs', '/builds')
      end

      it "redirects to new URL" do
        expect(page.current_path).to eq(job_url)
      end
    end

    feature 'Raw trace' do
      before do
        job.run!

        visit namespace_project_job_path(project.namespace, project, job)
      end

      it do
        expect(page).to have_css('.js-raw-link')
      end
    end

    feature 'HTML trace', :js do
      before do
        job.run!

        visit namespace_project_job_path(project.namespace, project, job)
      end

      context 'when job has an initial trace' do
        it 'loads job trace' do
          expect(page).to have_content 'BUILD TRACE'

          job.trace.write do |stream|
            stream.append(' and more trace', 11)
          end

          expect(page).to have_content 'BUILD TRACE and more trace'
        end
      end
    end

    feature 'Variables' do
      let(:trigger_request) { create(:ci_trigger_request_with_variables) }

      let(:job) do
        create :ci_build, pipeline: pipeline, trigger_request: trigger_request
      end

      before do
        visit namespace_project_job_path(project.namespace, project, job)
      end

      it 'shows variable key and value after click', js: true do
        expect(page).to have_css('.reveal-variables')
        expect(page).not_to have_css('.js-build-variable')
        expect(page).not_to have_css('.js-build-value')

        click_button 'Reveal Variables'

        expect(page).not_to have_css('.reveal-variables')
        expect(page).to have_selector('.js-build-variable', text: 'TRIGGER_KEY_1')
        expect(page).to have_selector('.js-build-value', text: 'TRIGGER_VALUE_1')
      end
    end

    context 'when job starts environment' do
      let(:environment) { create(:environment, project: project) }
      let(:pipeline) { create(:ci_pipeline, project: project) }

      context 'job is successfull and has deployment' do
        let(:deployment) { create(:deployment) }
        let(:job) { create(:ci_build, :success, environment: environment.name, deployments: [deployment], pipeline: pipeline) }

        it 'shows a link for the job' do
          visit namespace_project_job_path(project.namespace, project, job)

          expect(page).to have_link environment.name
        end
      end

      context 'job is complete and not successful' do
        let(:job) { create(:ci_build, :failed, environment: environment.name, pipeline: pipeline) }

        it 'shows a link for the job' do
          visit namespace_project_job_path(project.namespace, project, job)

          expect(page).to have_link environment.name
        end
      end

      context 'job creates a new deployment' do
        let!(:deployment) { create(:deployment, environment: environment, sha: project.commit.id) }
        let(:job) { create(:ci_build, :success, environment: environment.name, pipeline: pipeline) }

        it 'shows a link to latest deployment' do
          visit namespace_project_job_path(project.namespace, project, job)

          expect(page).to have_link('latest deployment')
        end
      end
    end
  end

  describe "POST /:project/jobs/:id/cancel", :js do
    context "Job from project" do
      before do
        job.run!
        visit namespace_project_job_path(project.namespace, project, job)
        find('.js-cancel-job').click()
      end

      it 'loads the page and shows all needed controls' do
        expect(page.status_code).to eq(200)
        expect(page).to have_content 'Retry'
      end
    end
  end

  describe "POST /:project/jobs/:id/retry" do
    context "Job from project", :js do
      before do
        job.run!
        visit namespace_project_job_path(project.namespace, project, job)
        find('.js-cancel-job').click()
        find('.js-retry-button').trigger('click')
      end

      it 'shows the right status and buttons', :js do
        expect(page).to have_http_status(200)
        page.within('aside.right-sidebar') do
          expect(page).to have_content 'Cancel'
        end
      end
    end

    context "Job that current user is not allowed to retry" do
      before do
        job.run!
        job.cancel!
        project.update(visibility_level: Gitlab::VisibilityLevel::PUBLIC)

        logout_direct
        login_with(create(:user))
        visit namespace_project_job_path(project.namespace, project, job)
      end

      it 'does not show the Retry button' do
        page.within('aside.right-sidebar') do
          expect(page).not_to have_content 'Retry'
        end
      end
    end
  end

  describe "GET /:project/jobs/:id/download" do
    before do
      job.update_attributes(artifacts_file: artifacts_file)
      visit namespace_project_job_path(project.namespace, project, job)
      click_link 'Download'
    end

    context "Build from other project" do
      before do
        job2.update_attributes(artifacts_file: artifacts_file)
        visit download_namespace_project_job_artifacts_path(project.namespace, project, job2)
      end

      it { expect(page.status_code).to eq(404) }
    end
  end

  describe 'GET /:project/jobs/:id/raw', :js do
    context 'access source' do
      context 'job from project' do
        before do
          Capybara.current_session.driver.headers = { 'X-Sendfile-Type' => 'X-Sendfile' }
          job.run!
          visit namespace_project_job_path(project.namespace, project, job)
          find('.js-raw-link-controller').click()
        end

        it 'sends the right headers' do
          expect(page.status_code).to eq(200)
          expect(page.response_headers['Content-Type']).to eq('text/plain; charset=utf-8')
          expect(page.response_headers['X-Sendfile']).to eq(job.trace.send(:current_path))
        end
      end

      context 'job from other project' do
        before do
          Capybara.current_session.driver.headers = { 'X-Sendfile-Type' => 'X-Sendfile' }
          job2.run!
          visit raw_namespace_project_job_path(project.namespace, project, job2)
        end

        it 'sends the right headers' do
          expect(page.status_code).to eq(404)
        end
      end
    end

    context 'storage form' do
      let(:existing_file) { Tempfile.new('existing-trace-file').path }

      before do
        Capybara.current_session.driver.headers = { 'X-Sendfile-Type' => 'X-Sendfile' }

        job.run!
      end

      context 'when job has trace in file', :js do
        before do
          allow_any_instance_of(Gitlab::Ci::Trace)
            .to receive(:paths)
            .and_return([existing_file])

          visit namespace_project_job_path(namespace, project, job)

          find('.js-raw-link-controller').click
        end

        it 'sends the right headers' do
          expect(page.status_code).to eq(200)
          expect(page.response_headers['Content-Type']).to eq('text/plain; charset=utf-8')
          expect(page.response_headers['X-Sendfile']).to eq(existing_file)
        end
      end

      context 'when job has trace in the database', :js do
        before do
          allow_any_instance_of(Gitlab::Ci::Trace)
            .to receive(:paths)
            .and_return([])

          visit namespace_project_job_path(namespace, project, job)
        end

        it 'sends the right headers' do
          expect(page).not_to have_selector('.js-raw-link-controller')
        end
      end
    end

    context "when visiting old URL" do
      let(:raw_job_url) do
        raw_namespace_project_job_path(project.namespace, project, job)
      end

      before do
        visit raw_job_url.sub('/-/jobs', '/builds')
      end

      it "redirects to new URL" do
        expect(page.current_path).to eq(raw_job_url)
      end
    end
  end

  describe "GET /:project/jobs/:id/trace.json" do
    context "Job from project" do
      before do
        visit trace_namespace_project_job_path(project.namespace, project, job, format: :json)
      end

      it { expect(page.status_code).to eq(200) }
    end

    context "Job from other project" do
      before do
        visit trace_namespace_project_job_path(project.namespace, project, job2, format: :json)
      end

      it { expect(page.status_code).to eq(404) }
    end
  end

  describe "GET /:project/jobs/:id/status" do
    context "Job from project" do
      before do
        visit status_namespace_project_job_path(project.namespace, project, job)
      end

      it { expect(page.status_code).to eq(200) }
    end

    context "Job from other project" do
      before do
        visit status_namespace_project_job_path(project.namespace, project, job2)
      end

      it { expect(page.status_code).to eq(404) }
    end
  end
end
